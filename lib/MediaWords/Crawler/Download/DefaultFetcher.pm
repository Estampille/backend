package MediaWords::Crawler::Download::DefaultFetcher;

#
# Default fetcher implementation
#
# In addition to the basic HTTP request with the user agent options supplied by
# MediaWords::Util::Web::UserAgent object, the default fetcher:
#
# * fixes common url mistakes like doubling http: (http://http://google.com).
# * follows meta refresh redirects in the response content
# * adds domain specific http auth specified in mediawords.yml
# * implements a very limited amount of site specific fixes
#

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use Moose::Role;
with 'MediaWords::Crawler::FetcherRole';

use MediaWords::DB;
use MediaWords::Util::Config;
use MediaWords::Util::SQL;
use MediaWords::Util::Web;
use MediaWords::Util::URL;

use URI;

# alarabiya uses an interstitial that requires javascript.  if the download url
# matches alarabiya and returns the 'requires JavaScript' page, manually parse
# out the necessary cookie and add it to the $ua so that the request will work
sub _fix_alarabiya_response
{
    my ( $download, $ua, $response ) = @_;

    return $response unless ( $download->{ url } =~ /alarabiya/ );

    if ( $response->decoded_content !~ /This site requires JavaScript and Cookies to be enabled/ )
    {
        return $response;
    }

    if ( $response->decoded_content =~ /setCookie\('([^']+)', '([^']+)'/ )
    {
        my $request = MediaWords::Util::Web::UserAgent::Request->new( 'GET', $download->{ url } );
        $request->set_header( 'Cookie', "$1=$2" );
        my $response = $ua->request( $request );

        return $response;
    }
    else
    {
        WARN "Unable to parse cookie from alarabiya: " . $response->decoded_content;
        return $response;
    }
}

# cache domain http auth lookup from config
my $_domain_http_auth_lookup;

# read the mediawords.crawler_authenticated_domains list from mediawords.yml and generate a lookup hash
# with the host domain as the key and the user:password credentials as the value.
sub _get_domain_http_auth_lookup
{
    return $_domain_http_auth_lookup if ( defined( $_domain_http_auth_lookup ) );

    my $config = MediaWords::Util::Config::get_config;

    my $domains = $config->{ mediawords }->{ crawler_authenticated_domains };

    map { $_domain_http_auth_lookup->{ lc( $_->{ domain } ) } = $_ } @{ $domains };

    return $_domain_http_auth_lookup;
}

# if there are http auth credentials for the requested site, add them to the request
sub _add_http_auth($)
{
    my ( $url ) = @_;

    my $auth_lookup ||= _get_domain_http_auth_lookup();

    my $domain = MediaWords::Util::URL::get_url_distinctive_domain( $url );

    if ( my $auth = $auth_lookup->{ lc( $domain ) } )
    {
        my $uri = URI->new( $url )->canonical;
        $uri->userinfo( $auth->{ user } . ':' . $auth->{ password } );
        $url = $uri->as_string;
    }

    return $url;
}

sub fetch_download($$$)
{
    my ( $self, $db, $download ) = @_;

    $download->{ download_time } = MediaWords::Util::SQL::sql_now;
    $download->{ state }         = 'fetching';

    $db->update_by_id( "downloads", $download->{ downloads_id }, $download );

    my $ua = MediaWords::Util::Web::UserAgent->new();

    my $url = $download->{ url };

    $url = MediaWords::Util::URL::fix_common_url_mistakes( $url );
    $url = _add_http_auth( $url );

    my $response = $ua->get_follow_http_html_redirects( $url );

    $response = _fix_alarabiya_response( $download, $ua, $response );

    return $response;
}

1;
