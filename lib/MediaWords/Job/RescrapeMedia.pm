package MediaWords::Job::RescrapeMedia;

#
# Search and add new feeds for unmoderated media (media sources that have not
# had default feeds added to them).
#
# Start this worker script by running:
#
# ./script/run_with_carton.sh local/bin/mjm_worker.pl lib/MediaWords/Job/RescrapeMedia.pm
#
# FIXME some output of the job is still logged to STDOUT and not to the log:
#
#    fetch [1/1] : http://www.delfi.lt/
#    got [1/1]: http://www.delfi.lt/
#    <...>
#
# That's because MediaWords::Util::Web::UserAgent->parallel_get() starts a child process
# for fetching URLs (instead of a fork()).
#

use strict;
use warnings;

use Moose;
with 'MediaWords::AbstractJob';

BEGIN
{
    use FindBin;

    # "lib/" relative to "local/bin/mjm_worker.pl":
    use lib "$FindBin::Bin/../../lib";
}

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use MediaWords::DB;
use MediaWords::DBI::Media::Rescrape;

sub use_job_state($)
{
    return 1;
}

# Run job
sub run_statefully($$;$)
{
    my ( $self, $db, $args ) = @_;

    my $media_id = $args->{ media_id };
    unless ( defined $media_id )
    {
        die "'media_id' is undefined.";
    }

    MediaWords::DBI::Media::Rescrape::rescrape_media( $db, $media_id );
}

no Moose;    # gets rid of scaffolding

# Return package name instead of 1 or otherwise worker.pl won't know the name of the package it's loading
__PACKAGE__;
