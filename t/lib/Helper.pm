use strictures 2;
# no package, so things defined here appear in the namespace of the parent.
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Safe::Isa;
use List::Util 'pairs';
use HTTP::Request;
use HTTP::Response;
use HTTP::Status ();
use Mojo::Message::Request;
use Mojo::Message::Response;
use Catalyst::Request;
use Catalyst::Response;
use Test2::API 'context_do';
use Test::Needs;

use DDP;

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use JSON::Schema::Modern::Document::OpenAPI;
use OpenAPI::Modern;
use Test::File::ShareDir -share => { -dist => { 'OpenAPI-Modern' => 'share' } };
use constant { true => JSON::PP::true, false => JSON::PP::false };
use YAML::PP 0.005;

# type can be
# 'mojo': classes of type Mojo::URL, Mojo::Headers, Mojo::Message::Request, Mojo::Message::Response
# 'lwp': classes of type URI, HTTP::Headers, HTTP::Request, HTTP::Response
# 'plack': classes of type Plack::Request, Plack::Response
# 'catalyst': classes of type Catalyst::Request, Catalyst::Response
our @TYPES = qw(mojo lwp plack catalyst);
our $TYPE;

# Note: if you want your query parameters or uri fragment to be normalized, set them afterwards
sub request ($method, $uri_string, $headers = [], $body_content = '') {
  die '$TYPE is not set' if not defined $TYPE;

  my $req;
  if ($TYPE eq 'lwp' or $TYPE eq 'plack') {
    my $uri = URI->new($uri_string);
    my $host = $uri->$_call_if_can('host');
    $req = HTTP::Request->new($method => $uri, [], $body_content);
    $req->headers->push_header(@$_) foreach pairs @$headers, $host ? (Host => $host) : ();
    $req->headers->header('Content-Length' => length($body_content))
      if defined $body_content and not defined $req->headers->header('Content-Length')
        and not defined $req->headers->header('Transfer-Encoding');
    $req->protocol('HTTP/1.1'); # required, but not added by HTTP::Request constructor
  }
  elsif ($TYPE eq 'mojo') {
    my $uri = Mojo::URL->new($uri_string);
    my $host = $uri->host;
    $req = Mojo::Message::Request->new(method => $method, url => Mojo::URL->new($uri_string));
    $req->headers->add(@$_) foreach pairs @$headers;
    $req->body($body_content) if defined $body_content;

    # add missing Content-Length, etc
    $req->fix_headers;
  }
  elsif ($TYPE eq 'catalyst') {
    my $uri = URI->new($uri_string);
    my $host = $uri->host;
    my $http_headers = HTTP::Headers->new;
    $http_headers->push_header(@$_) foreach pairs @$headers, $host ? (Host => $host) : ();
    $http_headers->header( 'Content-Length' => length($body_content) )
      if $body_content
        and not defined $http_headers->header('Content-Length')
          and not defined $http_headers->header('Transfer-Encoding');
    $req = Catalyst::Request->new(
        _log     => undef,     # to shut C::R up
        method   => $method,
        uri      => $uri,
        headers  => $http_headers,
        host     => $host,
        (body => $body_content) x!! $body_content,
    );
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  if ($TYPE eq 'plack') {
    test_needs('Plack::Request', 'HTTP::Message::PSGI', { 'HTTP::Headers::Fast' => 0.21 });
    my $uri = $req->uri;
    $req = Plack::Request->new($req->to_psgi);

    # Plack is unable to distinguish between %2F and /, so the raw (undecoded) uri can be passed
    # here. see PSGI::FAQ
    $req->env->{REQUEST_URI} = $uri . '';
  }

  return $req;
}

sub response ($code, $headers = [], $body_content = '') {
  die '$TYPE is not set' if not defined $TYPE;

  my $res;
  if ($TYPE eq 'lwp') {
    $res = HTTP::Response->new($code, HTTP::Status::status_message($code), @$headers ? $headers : (), length $body_content ? $body_content : ());
    $res->protocol('HTTP/1.1'); # not added by HTTP::Response constructor
    $res->headers->header('Content-Length' => length($body_content))
      if defined $body_content and not defined $res->headers->header('Content-Length')
        and not defined $res->headers->header('Transfer-Encoding');
  }
  elsif ($TYPE eq 'mojo') {
    $res = Mojo::Message::Response->new(code => $code);
    $res->message($res->default_message);
    $res->headers->add(@$_) foreach pairs @$headers;
    $res->body($body_content) if defined $body_content;

    # add missing Content-Length, etc
    $res->fix_headers;
  }
  elsif ($TYPE eq 'plack') {
    test_needs('Plack::Response', 'HTTP::Message::PSGI', { 'HTTP::Headers::Fast' => 0.21 });
    $res = Plack::Response->new($code, $headers, $body_content);
    $res->headers->header('Content-Length' => length($body_content))
      if defined $body_content and not defined $res->headers->header('Content-Length')
        and not defined $res->headers->header('Transfer-Encoding');
  }
  elsif ($TYPE eq 'catalyst') {
    p $body_content;
    my $http_headers = HTTP::Headers->new();
    $http_headers->push_header(@$_) foreach pairs @$headers;
    # have to do this ahead of time as C::Response won't let us touch them after
    $http_headers->header('Content-Length' => length($body_content))
      if $body_content and not defined $http_headers->header('Content-Length')
        and not defined $http_headers->header('Transfer-Encoding');
    p $http_headers;
    $res = Catalyst::Response->new(
      headers => $http_headers,
      status => $code,
      (body => $body_content) x!! $body_content,
    );
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $res;
}

sub uri ($uri_string, @path_parts) {
  die '$TYPE is not set' if not defined $TYPE;

  my $uri;
  if ($TYPE eq 'lwp' or $TYPE eq 'plack' or $TYPE eq 'catalyst') {
    $uri = URI->new($uri_string);
    $uri->path_segments(@path_parts) if @path_parts;
  }
  elsif ($TYPE eq 'mojo') {
    $uri = Mojo::URL->new($uri_string);
    $uri->path->parts(\@path_parts) if @path_parts;
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $uri;
}

# sets query parameters on the request
sub query_params ($request, $pairs) {
  die '$TYPE is not set' if not defined $TYPE;

  my $uri;
  if ($TYPE eq 'lwp') {
    $request->uri->query_form($pairs);
  }
  elsif ($TYPE eq 'mojo') {
    $request->url->query->pairs($pairs);
  }
  elsif ($TYPE eq 'plack') {
    # this is the encoded query string portion of the URI
    $request->env->{QUERY_STRING} = Mojo::Parameters->new->pairs($pairs)->to_string;
    $request->env->{REQUEST_URI} .= '?' . $request->env->{QUERY_STRING};
  }
  elsif ($TYPE eq 'catalyst') {
    $request->query_parameters($pairs);
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }

  return $uri;
}

sub remove_header ($message, $header_name) {
  die '$TYPE is not set' if not defined $TYPE;

  if ($TYPE eq 'lwp' || $TYPE eq 'catalyst') {
    $message->headers->remove_header($header_name);
  }
  elsif ($TYPE eq 'mojo') {
    $message->headers->remove($header_name);
  }
  elsif ($TYPE eq 'plack') {
    $message->headers->remove_header($header_name);
    delete $message->env->{uc $header_name =~ s/-/_/r} if $message->isa('Plack::Request');
  }
  else {
    die '$TYPE '.$TYPE.' not supported';
  }
}

# create a Result object out of the document errors; suitable for stringifying
# as the OpenAPI::Modern constructor might do.
sub document_result ($document) {
  JSON::Schema::Modern::Result->new(
    valid => $document->has_errors,
    errors => [ $document->errors ],
  );
}

# deep comparison, with strict typing
sub is_equal ($x, $y, $test_name = undef) {
  context_do {
    my $ctx = shift;
    my ($x, $y, $test_name) = @_;
    my $equal = JSON::Schema::Modern::Utilities::is_equal($x, $y, my $state = {});
    if ($equal) {
      $ctx->pass($test_name);
    }
    else {
      $ctx->fail($test_name);
      $ctx->note('structures differ'.($state->{path} ? ' starting at '.$state->{path} : ''));
    }
    return $equal;
  } $x, $y, $test_name;
}

1;
