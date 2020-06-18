#!/usr/bin/env perl

use Dancer2;

use LWP;
use HTTP::Request;
use JSON::XS qw(decode_json encode_json);
use DBI;
use Data::Dumper;

# for getting the location of the script
use FindBin qw($Script $Bin);

use Getopt::Long qw(GetOptions);

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

use vars qw(%OPT @OPTSTR $CMDLINE);

sub getArgs {
    Getopt::Long::Configure(qw(bundling no_getopt_compat no_auto_abbrev no_ignore_case_always));
    
    @OPTSTR=( 
        "help|h=s",
        "run|r",
        "maxPage=s",
        "page=s",
        "debug",
    );
    
    unless( @ARGV ){ 
        showHelp();
        exit 0;
    }else{
        $CMDLINE = join(' ',@ARGV);
        GetOptions(\%OPT,@OPTSTR);
    }
}

sub showHelp {
    my $s = qq{

    PICTURE STORAGE RESTFUL API 

    USAGE
        $Script OPTIONS
    OPTIONS
        -h --help show help
        -r --run  the script

        -d --debug  enable debugging

        --maxPage INT 
        --page INT 

    EXAMPLES
        $Script -r 
            simply run the app with loading pictures all at once

        $Script -r --maxPage 2
        $Script -r --page 1

    };

    print $s . "\n";
}

# for making HTTP requests

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

    debug('request:',Dumper($req->as_string));

    $res = $ua->request($req);

    debug('response:',Dumper($res->as_string));

    return $res;
}

sub debug {
    my @msg = @_;

    return unless $OPT{debug};

    for(@msg){
        print $_ . "\n";
    }

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

sub getPicsServer {
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
            warn "maximal number of tries for getPicsServer\n";
            return;
        }
        return getPicsServer($page,$id);
    }

    return $data;
}

# initialize the SQLITE database by creating table 'pictures'
#   database file will be stored in the same directory
#   as the script itself

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

# insert picture data into the SQLITE database (after splitting tags)

sub insertPictureDB {
    my ($pic) = @_;

    my @fields = keys %$pic;
    my $fieldString = join("," => @fields);
    my $quoteString = join("," => ( map { '?' } @fields ));

    my $sth;

    # do not insert tags repeatedly
    my $tag = $pic->{tag};
    my $id  = $pic->{id};

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

# insert picture data with the specific ID into the SQLITE database
#   the actual database inserting will be performed
#   in insertPictureDB subroutine
#   after the 'tags' string has been splitted

sub insertPicture {
    my ($pic) = @_;

    # for testing purposes
    $picNum++;
    return if $numPics && $picNum > $numPics;
    print 'Inserting picture number ' . $picNum . "\n";

    my $id = $pic->{id};

    my $data = getPicsServer(undef,$id);
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

    my $data = getPicsServer($page);
    $page ||= $data->{page};

    my $pageCount = $data->{pageCount};
    my $hasMore   = $data->{hasMore};
    my $pics      = $data->{pictures};

    $maxPage ||= $pageCount;

    foreach my $pic (@$pics) {
        insertPicture($pic);
    }

    my $loadMore = ( $page == 1 
            && !$OPT{page} 
            && $hasMore 
            && $maxPage 
            && $maxPage > 1 ) ? 1 : 0;

    my $minPage = $page + 1;

    if ($loadMore) {
        my @pages = ( $minPage .. $maxPage );
        foreach my $p (@pages) {
            updateCache($p);
        }
    }

}

# perform database, authorization token initialization;
#   and then fill the cache DB with the picture data
#   from the external values

sub appInit {

    # initialize database for caching pictures
    initDatabase() unless $dbh;

    # receive the authorization token
    updateToken() unless $authToken;


    # fill the cache database from the external server
    updateCache(@OPT{qw(page maxPage)});
}

sub jsonGetPictures {
    my $q = qq{ SELECT * FROM pictures };

    # execute SQL query
    my $sth = $dbh->prepare($q);
    $sth->execute();

    my @pictures;

    while( my $row = $sth->fetchrow_hashref ){
        push @pictures, $row;
    }

    # return the JSON response
    return encode_json({ 
       'pictures' => \@pictures,
       # number of pictures 
       'count'    => scalar @pictures
    });
}

# will be called when GET /search/:term is sent

sub jsonSearchTerm {
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

sub makeRoutes {
    get '/pictures' => sub {
        jsonGetPictures();
    };
    
    # search route
    get '/search/:term' => sub {
        jsonSearchTerm();
    };
}

sub appRun {
    # grab command-line arguments
    getArgs();

    # initialize
    appInit();

    # create routes
    makeRoutes();
    
    # run the web-server
    dance;
}

# run the application
appRun();

