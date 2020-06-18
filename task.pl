#!/usr/bin/env perl

use Dancer2;

use LWP;
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use DBI;

# for getting the location of the script
use FindBin qw($Bin);

# fields over which searching will be performed
#   urls are not processed
my @searchFields = qw(tag author camera);

my $baseUrl = "http://interview.agileengine.com";

# variable for storing the authorization token
my $authToken;

# SQLITE database handle to be used via DBI
my $dbh;

# for testing purposes, maximal number of pics
#   to be loaded from the external server upon initialization
my $numPics;
my $picNum=0;

sub makeRequest {
    my ($url, $method, $headers, $data) = @_;

    $method ||= 'GET';

    $headers ||= {};
    $headers->{'Authorization'} = "Bearer $authToken" if $authToken;

    $headers = { 
        'Content-Type' => 'application/json', 
        %$headers 
    };

    my ($ua,$req,$res,$content);
    
    $ua  = LWP::UserAgent->new();   
    $ua->agent('Mozilla/8.0');

    $req = HTTP::Request->new($method => $url); 
    $req->header(%$headers);
    $req->content($data) if $data;

    $res = $ua->request($req);

    return $res;
}


# obtain the authorization token from the server

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

# obtain pictures either via page number or a picture ID

my $counter = 0;
my $nTries = 2;

sub getImages {
    my ($page,$id) = @_;

    my $url = $baseUrl . '/images';
    $url .= qq{?page=$page} if $page;
    $url .= qq{/$id} if $id;

    my $res = makeRequest($url,'GET');

    my $data = decode_json($res->content);

    # in case authorization attempt has been failed
    #   keep trying for a specified number of times
    my $status = $data->{'status'};
    if($status && $status eq 'Unauthorized') {
        updateToken();
        $counter++;

        if ($counter == $nTries + 1) {
            warn "maximal number of tries for getImages\n";
            return;
        }
        return getImages($page,$id);
    }

    return $data;
}

sub initDatabase(){
    my $dbname = $Bin . '/task.db';
    $dbh = DBI->connect('dbi:SQLite:dbname='.$dbname,
        '','',{AutoCommit=>1,RaiseError=>1,PrintError=>0}
    );

    my $q = q{
        CREATE TABLE IF NOT EXISTS pictures (
            id TEXT,
            cropped_picture TEXT,
            author TEXT,
            camera TEXT,
            tag TEXT,
            full_picture TEXT
        )
    };
    $dbh->do($q);
}

sub insertPictureDB {
    my ($pic) = @_;

    my @fields = keys %$pic;
    my $fieldString = join("," => @fields);
    my $quoteString = join("," => ( map { '?' } @fields ));

    my $sth;

    #do not insert tags repeatedly
    my $tag = $pic->{tag};
    my $id = $pic->{id};

    $sth = $dbh->prepare(qq{SELECT COUNT(*) FROM pictures WHERE tag = ? AND id = ? });
    $sth->execute($tag, $id);
    my ($count) = $sth->fetchrow_array;

    return if $count;

    my $q = qq{
        INSERT INTO pictures ($fieldString) VALUES ($quoteString)
    };

    $sth = $dbh->prepare($q);
    $sth->execute(@$pic{@fields});
}

sub insertPicture {
    my ($pic) = @_;

    # for testing purposes
    $picNum++;
    return if $numPics && $picNum > $numPics;
    print 'Inserting picture number ' . $picNum . "\n";

    my $id = $pic->{id};

    my $data = getImages(undef,$id);
    $pic = { %$pic, %$data } if $data;

    my $tagString = $pic->{tags};
    my @tags;
    if ($tagString) {
        @tags = split /\s+/ => $tagString;
        s/^#//g for(@tags); 
    }

    delete $pic->{tags};

    if (@tags) {
        foreach my $tag (@tags) {
            $pic->{tag}=$tag;
            insertPictureDB($pic);
        }
    }else{
        insertPictureDB($pic);
    }

}

# fill the cache database from the external server
# usage: 
#   updateCache() for loading all pictures
#   updateCache(undef,2) for loading just 2 pages 
#   updateCache(1) for loading page 1

sub updateCache {
    my ($page,$maxPage) = @_;

    my $data = getImages($page);
    $page ||= $data->{page};

    my $pageCount = $data->{pageCount};
    my $hasMore   = $data->{hasMore};
    my $pics      = $data->{pictures};

    $maxPage ||= $pageCount;

    foreach my $pic (@$pics) {
        insertPicture($pic);
    }

    if ($page == 1 && $hasMore && $maxPage && $maxPage > 1) {
        my @pages = ( 2 .. $maxPage );
        foreach my $p (@pages) {
            updateCache($p);
        }
    }

}


sub init {
    # initialize database for caching pictures
    initDatabase() unless $dbh;

    # receive the authorization token
    updateToken() unless $authToken;

    # fill the cache database from the external server
    updateCache();
}

sub searchTerm {
    my $term = route_parameters->get('term');
    
    my $w = join(" OR ", 
        map { qq{
            $_ LIKE '%$term%' 
                OR $_ LIKE '$term%'
                OR $_ LIKE '%$term'
            } 
        } @searchFields );

    my $q = qq{SELECT * FROM pictures WHERE $w };

    # execute SQL query
    my $sth = $dbh->prepare($q);
    $sth->execute();

    my $data={};

    # retrieve and process results from the executed SQL query
    while(my $row = $sth->fetchrow_hashref){
        my $id = $row->{id};
        my $tag = $row->{tag};

        # delete the tag field since we do not need it
        #   in our final data
        delete $row->{tag};

        $data->{$id} ||= $row;

        unless($data->{$id}->{tags}){
            my $sth = $dbh->prepare(qq{
                SELECT tag FROM pictures WHERE id = ?
            });
            $sth->execute($id);
            my $tags = $sth->fetchall_arrayref;
            $data->{$id}->{tags} .= 
                join(" ",map { '#' . shift @$_ } @$tags );
        }

    }

    my @pictures;
    foreach my $id (keys %$data) {
        push @pictures, $data->{$id};
    }

    # return the JSON response
    return encode_json({ 
       'pictures' => \@pictures,
       # number of pictures 
       'count'    => scalar @pictures
    });

}

# initialize
init();

# search route
get '/search/:term' => sub {
    searchTerm();
};

# run the web-server
dance;


