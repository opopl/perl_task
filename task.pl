#!/usr/bin/env perl

use Dancer2;

use LWP;
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);

my $baseUrl = "http://interview.agileengine.com";
my $imageCache;

my $authToken;

sub makeRequest {
    my ($url, $method, $headers, $data) = @_;

    $method ||= 'GET';

    $headers ||= {};
    $headers = { 
        'content-type' => 'application/json', 
        'Authorization' =>  "Bearer $authToken",
        %$headers 
    };

    my ($ua,$req,$res,$content);
    
    $ua  = LWP::UserAgent->new();   
    $req = HTTP::Request->new($method => $url); 
    $req->headers(%$headers);
    $req->content($data) if $data;

    $res = $ua->request($req);
    
    return $res;
}


sub updateToken {
    my $res = makeRequest(
        $baseUrl . '/auth','POST',{},
        encode_json({"apiKey" => "23567b218376f79d9415"}),
    );

    my $data = decode_json($res->content);

    if ($data && $data->{auth}) {
        $authToken = $data->{token};
    }
}

my $counter = 0;
my $nTries = 2;

sub getImages {
    my ($page) = @_;

    my $url = $baseUrl . '/images';
    $url .= qq{?page=$page} if $page;

    my $res = makeRequest($url,'GET');

    my $data = decode_json($res->content);
    my $status = $data->{'status'};

    if($status eq 'Unauthorized') {
        updateToken();
        $counter++;

        if ($counter == $nTries + 1) {
            warn "maximal number of tries for getImages\n";
            return;
        }
        return getImages();
    }

    return $data;
}

sub updateCache {
    my $data = getImages();

    my $pageCount = $data->{pageCount};
    my $hasMore = $data->{hasMore};
    my $page = $data->{page};
}


sub init {
    updateToken() unless $authToken;
    updateCache() unless $imageCache;
}

get '/search/:term' => sub {
    init();
};

 
dance;


