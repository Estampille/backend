package MediaWords::DBI::Downloads;
use Modern::Perl "2013";
use MediaWords::CommonLibs;

# various helper functions for downloads

use strict;

use MediaWords::Crawler::Extractor;
use MediaWords::Util::Config;
use MediaWords::Util::HTML;
use MediaWords::DBI::DownloadTexts;
use MediaWords::StoryVectors;
use MediaWords::Util::Paths;
use MediaWords::KeyValueStore::AmazonS3;
use MediaWords::KeyValueStore::DatabaseInline;
use MediaWords::KeyValueStore::GridFS;
use MediaWords::KeyValueStore::LocalFile;
use MediaWords::KeyValueStore::PostgreSQL;
use MediaWords::KeyValueStore::Remote;
use MediaWords::KeyValueStore::Tar;
use Carp;
use MediaWords::Util::ExtractorFactory;
use MediaWords::Util::HeuristicExtractor;
use MediaWords::Util::CrfExtractor;
use MediaWords::GearmanFunction::AnnotateWithCoreNLP;

use Data::Dumper;

# Download store instances
my $_databaseinline_store;
my $_localfile_store;
my $_postgresql_store;
my $_tar_store;
my $_amazon_s3_store;    # might be nil if not configured
my $_gridfs_store;       # might be nil if not configured
my $_remote_store;       # might be nil if not configured

# Database inline content length limit
use constant INLINE_CONTENT_LENGTH => 256;

# Constructor
BEGIN
{
    # Early sanity check on configuration
    my $config = MediaWords::Util::Config::get_config;

    my $download_storage_locations = $config->{ mediawords }->{ download_storage_locations };
    if ( scalar( @{ $download_storage_locations } ) == 0 )
    {
        die "No download storage methods are configured.\n";
    }
    foreach my $download_storage_location ( @{ $download_storage_locations } )
    {
        my $location = lc( $download_storage_location );
        unless ( grep { $_ eq $location } ( 'amazon_s3', 'gridfs', 'localfile', 'postgresql', 'tar' ) )
        {
            die "Download storage location '$download_storage_location' is not valid.\n";
        }
    }

    my %enabled_download_storage_locations = map { $_ => 1 } @{ $download_storage_locations };

    # Test if all enabled storage locations are also configured
    if ( exists( $enabled_download_storage_locations{ 'amazon_s3' } ) )
    {
        unless ( $config->{ amazon_s3 } )
        {
            die "'amazon_s3' storage location is enabled, but Amazon S3 is not configured.\n";
        }
    }
    if ( exists( $enabled_download_storage_locations{ 'gridfs' } ) )
    {
        unless ( $config->{ mongodb_gridfs } )
        {
            die "'gridfs' storage location is enabled, but MongoDB GridFS is not configured.\n";
        }
    }

    # Initialize key value stores for downloads
    if ( $config->{ amazon_s3 } )
    {
        $_amazon_s3_store = MediaWords::KeyValueStore::AmazonS3->new(
            {
                bucket_name    => $config->{ amazon_s3 }->{ downloads }->{ bucket_name },
                directory_name => $config->{ amazon_s3 }->{ downloads }->{ directory_name }
            }
        );
    }

    $_databaseinline_store = MediaWords::KeyValueStore::DatabaseInline->new(
        {
            # no arguments are needed
        }
    );

    if ( $config->{ mongodb_gridfs } )
    {
        $_gridfs_store = MediaWords::KeyValueStore::GridFS->new(
            { database_name => $config->{ mongodb_gridfs }->{ downloads }->{ database_name } } );
    }

    $_localfile_store =
      MediaWords::KeyValueStore::LocalFile->new( { data_content_dir => MediaWords::Util::Paths::get_data_content_dir } );

    $_postgresql_store = MediaWords::KeyValueStore::PostgreSQL->new( { table_name => 'raw_downloads' } );

    if ( $config->{ mediawords }->{ fetch_remote_content_url } )
    {
        $_remote_store = MediaWords::KeyValueStore::Remote->new(
            {
                url      => $config->{ mediawords }->{ fetch_remote_content_url },
                username => $config->{ mediawords }->{ fetch_remote_content_user },
                password => $config->{ mediawords }->{ fetch_remote_content_password }
            }
        );
    }

    $_tar_store =
      MediaWords::KeyValueStore::Tar->new( { data_content_dir => MediaWords::Util::Paths::get_data_content_dir } );
}

# Returns arrayref of stores for writing new downloads to
sub _download_stores_for_writing($)
{
    my $content_ref = shift;

    my $stores = [];

    if ( length( $$content_ref ) < INLINE_CONTENT_LENGTH )
    {
        unless ( $_databaseinline_store )
        {
            die "DatabaseInline store is not initialized, although it is required by _download_stores_for_writing().\n";
        }

        # Inline
        #say STDERR "Will store inline.";
        push( @{ $stores }, $_databaseinline_store );
    }
    else
    {
        my $config = MediaWords::Util::Config::get_config;

        my $download_storage_locations = $config->{ mediawords }->{ download_storage_locations };
        foreach my $download_storage_location ( @{ $download_storage_locations } )
        {
            my $location = lc( $download_storage_location );

            if ( $location eq 'amazon_s3' )
            {
                unless ( $_amazon_s3_store )
                {
                    die "AmazonS3 store is not initialized, although it is required by _download_stores_for_writing().\n";
                }

                #say STDERR "Will store to Amazon S3.";
                push( @{ $stores }, $_amazon_s3_store );

            }
            elsif ( $location eq 'gridfs' )
            {
                unless ( $_gridfs_store )
                {
                    die "GridFS store is not initialized, although it is required by _download_stores_for_writing().\n";
                }

                #say STDERR "Will store to GridFS.";
                push( @{ $stores }, $_gridfs_store );

            }
            elsif ( $location eq 'localfile' )
            {
                unless ( $_localfile_store )
                {
                    die
"DatabaseInline store is not initialized, although it is required by _download_stores_for_writing().\n";
                }

                #say STDERR "Will store to local files.";
                push( @{ $stores }, $_localfile_store );

            }
            elsif ( $location eq 'postgresql' )
            {
                unless ( $_postgresql_store )
                {
                    die
"DatabaseInline store is not initialized, although it is required by _download_stores_for_writing().\n";
                }

                #say STDERR "Will store to PostgreSQL.";
                push( @{ $stores }, $_postgresql_store );

            }
            elsif ( $location eq 'tar' )
            {
                unless ( $_tar_store )
                {
                    die
"DatabaseInline store is not initialized, although it is required by _download_stores_for_writing().\n";
                }

                #say STDERR "Will store to Tar.";
                push( @{ $stores }, $_tar_store );

            }
            else
            {
                die "Download storage location '$location' is not valid.\n";
            }
        }
    }

    if ( scalar( @{ $stores } ) == 0 )
    {
        die "No download storage locations are configured.\n";
    }

    return $stores;
}

# Returns store for fetching downloads from
sub _download_store_for_reading($)
{
    my $download = shift;

    my $store;

    my $config = MediaWords::Util::Config::get_config;

    my $fetch_remote = $config->{ mediawords }->{ fetch_remote_content } || 'no';
    if ( $fetch_remote eq 'yes' )
    {
        unless ( $_remote_store )
        {
            die
"Remote store is not initialized, although it is required by _download_store_for_reading() for fetching download "
              . $download->{ downloads_id } . ".\n";
        }

        # Remote
        $store = $_remote_store;
    }
    else
    {
        my $path = $download->{ path };
        if ( !$path )
        {
            $store = undef;
        }
        elsif ( $path =~ /^content:(.*)/ )
        {
            unless ( $_databaseinline_store )
            {
                die
"DatabaseInline store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                  . $download->{ downloads_id } . ".\n";
            }

            # Inline content
            $store = $_databaseinline_store;
        }
        elsif ( $path =~ /^gridfs:(.*)/ )
        {
            unless ( $_gridfs_store )
            {
                die
"GridFS store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                  . $download->{ downloads_id } . ".\n";
            }

            # GridFS
            $store = $_gridfs_store;
        }
        elsif ( $path =~ /^postgresql:(.*)/ )
        {
            unless ( $_postgresql_store )
            {
                die
"PostgreSQL store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                  . $download->{ downloads_id } . ".\n";
            }

            # PostgreSQL
            $store = $_postgresql_store;
        }
        elsif ( $path =~ /^s3:(.*)/ )
        {
            unless ( $_amazon_s3_store )
            {
                die
"AmazonS3 store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                  . $download->{ downloads_id } . ".\n";
            }

            # Amazon S3
            $store = $_amazon_s3_store;
        }
        elsif ( $download->{ path } =~ /^tar:/ )
        {

            # Tar
            if ( lc( $config->{ mediawords }->{ read_tar_downloads_from_gridfs } ) eq 'yes' )
            {
                unless ( $_gridfs_store )
                {
                    die
"GridFS store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                      . $download->{ downloads_id } . ".\n";
                }

                # Force reading Tar downloads from GridFS (after the migration)
                $store = $_gridfs_store;
            }
            else
            {
                unless ( $_tar_store )
                {
                    die
"Tar store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                      . $download->{ downloads_id } . ".\n";
                }

                $store = $_tar_store;
            }
        }
        else
        {

            # Local file
            if ( lc( $config->{ mediawords }->{ read_file_downloads_from_gridfs } ) eq 'yes' )
            {
                unless ( $_gridfs_store )
                {
                    die
"GridFS store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                      . $download->{ downloads_id } . ".\n";
                }

                # Force reading file downloads from GridFS (after the migration)
                $store = $_gridfs_store;
            }
            else
            {
                unless ( $_localfile_store )
                {
                    die
"LocalFile store is not initialized, although it is required by _download_store_for_reading() for fetching download "
                      . $download->{ downloads_id } . ".\n";
                }

                $store = $_localfile_store;
            }

        }
    }

    return $store;
}

# fetch the content for the given download as a content_ref
sub fetch_content($$)
{
    my ( $db, $download ) = @_;

    carp "fetch_content called with invalid download " unless exists $download->{ downloads_id };

    carp "attempt to fetch content for unsuccessful download $download->{ downloads_id }  / $download->{ state }"
      unless $download->{ state } eq 'success';

    my $config = MediaWords::Util::Config::get_config;

    my $store = _download_store_for_reading( $download );
    unless ( defined $store )
    {
        die "No download path or the state is not 'success' for download ID " . $download->{ downloads_id };
    }

    # Fetch content
    if ( my $content_ref = $store->fetch_content( $db, $download->{ downloads_id }, $download->{ download_path } ) )
    {

        # horrible hack to fix old content that is not stored in unicode
        my $ascii_hack_downloads_id = $config->{ mediawords }->{ ascii_hack_downloads_id };
        if ( $ascii_hack_downloads_id && ( $download->{ downloads_id } < $ascii_hack_downloads_id ) )
        {
            $$content_ref =~ s/[^[:ascii:]]/ /g;
        }

        return $content_ref;
    }
    else
    {
        warn "Unable to fetch content for download " . $download->{ downloads_id } . "\n";

        my $ret = '';
        return \$ret;
    }
}

# fetch the content as lines in an array after running through the extractor preprocessor
sub fetch_preprocessed_content_lines($$)
{
    my ( $db, $download ) = @_;

    my $content_ref = fetch_content( $db, $download );

    # print "CONTENT:\n**\n${ $content_ref }\n**\n";

    if ( !$content_ref )
    {
        warn( "unable to find content: " . $download->{ downloads_id } );
        return [];
    }

    my $lines = [ split( /[\n\r]+/, $$content_ref ) ];

    $lines = MediaWords::Crawler::Extractor::preprocess( $lines );

    return $lines;
}

# run MediaWords::Crawler::Extractor against the download content and return a hash in the form of:
# { extracted_html => $html,    # a string with the extracted html
#   extracted_text => $text,    # a string with the extracted html strippped to text
#   download_lines => $lines,   # an array of the lines of original html
#   scores => $scores }         # the scores returned by Mediawords::Crawler::Extractor::score_lines
sub extractor_results_for_download($$)
{
    my ( $db, $download ) = @_;

    my $story = $db->query( "select * from stories where stories_id = ?", $download->{ stories_id } )->hash;

    my $lines = fetch_preprocessed_content_lines( $db, $download );

    # print "PREPROCESSED LINES:\n**\n" . join( "\n", @{ $lines } ) . "\n**\n";

    return extract_preprocessed_lines_for_story( $lines, $story->{ title }, $story->{ description } );
}

# if the given line looks like a tagline for another story and is missing an ending period, add a period
#
sub add_period_to_tagline($$$)
{
    my ( $lines, $scores, $i ) = @_;

    if ( ( $i < 1 ) || ( $i >= ( @{ $lines } - 1 ) ) )
    {
        return;
    }

    if ( $scores->[ $i - 1 ]->{ is_story } || $scores->[ $i + 1 ]->{ is_story } )
    {
        return;
    }

    if ( $lines->[ $i ] =~ m~[^\.]\s*</[a-z]+>$~i )
    {
        $lines->[ $i ] .= '.';
    }
}

sub _do_extraction_from_content_ref($$$)
{
    my ( $content_ref, $title, $description ) = @_;

    my $lines = [ split( /[\n\r]+/, $$content_ref ) ];

    $lines = MediaWords::Crawler::Extractor::preprocess( $lines );

    return extract_preprocessed_lines_for_story( $lines, $title, $description );
}

sub _get_included_line_numbers($)
{
    my $scores = shift;

    my @included_lines;
    for ( my $i = 0 ; $i < @{ $scores } ; $i++ )
    {
        if ( $scores->[ $i ]->{ is_story } )
        {
            push @included_lines, $i;
        }
    }

    return \@included_lines;
}

sub extract_preprocessed_lines_for_story($$$)
{
    my ( $lines, $story_title, $story_description ) = @_;

    my $old_extractor = MediaWords::Util::ExtractorFactory::createExtractor();

    return $old_extractor->extract_preprocessed_lines_for_story( $lines, $story_title, $story_description );
}

# store the download content in the file system
sub store_content($$$)
{
    my ( $db, $download, $content_ref ) = @_;

    #say STDERR "starting store_content for download $download->{ downloads_id } ";

    my $new_state = 'success';
    if ( $download->{ state } eq 'feed_error' )
    {
        $new_state = $download->{ state };
    }

    # Store content
    my $path = '';
    eval {
        my $stores_for_writing = _download_stores_for_writing( $content_ref );
        if ( scalar( @{ $stores_for_writing } ) == 0 )
        {
            die "No download stores configured to write to.\n";
        }
        foreach my $store ( @{ $stores_for_writing } )
        {
            $path = $store->store_content( $db, $download->{ downloads_id }, $content_ref );
        }

        # Now $path points to the last store that was configured
    };
    if ( $@ )
    {
        die "Error while trying to store download ID " . $download->{ downloads_id } . ':' . $@;
        $new_state = 'error';
        $download->{ error_message } = $@;
    }
    elsif ( $new_state eq 'success' )
    {
        $download->{ error_message } = '';
    }

    # Update database
    $db->query(
        <<"EOF",
        UPDATE downloads
        SET state = ?,
            path = ?,
            error_message = ?,
            file_status = DEFAULT       -- Reset the file_status in case
                                        -- this download is being redownloaded
        WHERE downloads_id = ?
EOF
        $new_state,
        $path,
        $download->{ error_message },
        $download->{ downloads_id }
    );

    $download->{ state } = $new_state;
    $download->{ path }  = $path;

    $download = $db->find_by_id( 'downloads', $download->{ downloads_id } );

    return $download;
}

# try to store content determinedly by retrying on a failed eval at doubling increments up to 32 seconds
sub store_content_determinedly
{
    my ( $db, $download, $content ) = @_;

    my $interval = 1;
    while ( 1 )
    {
        eval { store_content( $db, $download, \$content ) };
        return unless ( $@ );

        if ( $interval < 33 )
        {
            warn( "store_content failed: $@\ntrying again..." );
            $interval *= 2;
            sleep( $interval );
        }
        else
        {
            warn( "store_content_determinedly failed: $@" );
            return;
        }
    }
}

# convenience method to get the media_id for the download
sub get_media_id($$)
{
    my ( $db, $download ) = @_;

    my $feeds_id = $download->{ feeds_id };

    $feeds_id || die $db->error;

    my $media_id = $db->query( "SELECT media_id from feeds where feeds_id = ?", $feeds_id )->hash->{ media_id };

    defined( $media_id ) || die "Could not get media id for feeds_id '$feeds_id " . $db->error;

    return $media_id;
}

# convenience method to get the media source for the given download
sub get_medium($$)
{
    my ( $db, $download ) = @_;

    my $media_id = get_media_id( $db, $download );

    my $medium = $db->find_by_id( 'media', $media_id );

    return $medium;
}

sub process_download_for_extractor($$$;$$$)
{
    my ( $db, $download, $process_num, $no_dedup_sentences, $no_vector ) = @_;

    # Extract
    say STDERR "[$process_num] extract: $download->{ downloads_id } $download->{ stories_id } $download->{ url }";
    my $download_text = MediaWords::DBI::DownloadTexts::create_from_download( $db, $download );

    unless ( $no_vector )
    {

        # Vector
        my $remaining_download = $db->query(
            <<EOF,
            SELECT downloads_id
            FROM downloads
            WHERE stories_id = ?
              AND extracted = 'f'
              AND type = 'content'
EOF
            $download->{ stories_id }
        )->hash;
        if ( !$remaining_download )
        {
            my $story = $db->find_by_id( 'stories', $download->{ stories_id } );

            MediaWords::StoryVectors::update_story_sentence_words_and_language( $db, $story, 0, $no_dedup_sentences );
        }
        else
        {
            say STDERR "[$process_num] pending more downloads ...";
        }
    }

    my $media = get_medium( $db, $download );
    if ( $media->{ annotate_with_corenlp } )
    {
        # Enqueue for CoreNLP annotation
        MediaWords::GearmanFunction::AnnotateWithCoreNLP->enqueue_on_gearman( $download );
    }
}

1;
