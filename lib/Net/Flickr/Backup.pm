# $Id: Backup.pm,v 1.43 2005/09/01 22:41:33 asc Exp $
use strict;

package Net::Flickr::Backup;
$Net::Flickr::Backup::VERSION = '1.2';

=head1 NAME

Net::Flickr::Backup - OOP for backing up your Flickr photos locally

=head1 SYNOPSIS

    use Net::Flickr::Backup;
    use Log::Dispatch::Screen;
    
    my $flickr = Net::Flickr::Backup->new("/path/to/backup.cfg");

    my $feedback = Log::Dispatch::Screen->new('name'      => 'info',
					      'min_level' => 'info');

    $flickr->log()->add($feedback);
    $flickr->backup(); 

=head1 DESCRIPTION

OOP for backing up your Flickr photos locally.

=head1 OPTIONS

Options are passed to Net::Flickr::Backup using a Config::Simple object or
a valid Config::Simple config file. Options are grouped by "block".

=head2 flick

=over 4

=item * B<api_key>

String. I<required>

A valid Flickr API key.

=item * B<api_secret>

String. I<required>

A valid Flickr Auth API secret key.

=item * B<auth_token>

String. I<required>

A valid Flickr Auth API token.

=back

=head2 backup

=over 4

=item * B<photos_root>

String. I<required>

The root folder where you want photographs to be stored. Individual
files are named using the following pattern :

  B<photos_root>/B<YYYY>/B<MM>/B<DD>/B<YYYYMMDD>-B<photo_id>-B<clean_title>_B<size>.jpg

Where the various components are :

=over 4

=item * B<YYYYMMDD>

 photo[@id=123]/dates/@taken

=item * B<photo_id>

photo/@id

=item * B<clean_title>

 photo[@id=123]/title

Unicode characters translated in to ASCII (using Text::Unidecode) and the
entire string is stripped anything that is not an alphanumeric, underbar,
dash or a square bracket.

=item * B<size>

Net::Flickr::Backup will attempt to fetch not only the original file uploaded
to Flickr but also, depending on your config options, the medium and square
versions. Filenames will be modified as follows :

=over 4 

=item * B<original>

The original photo you uploaded to the Flickr servers. No extension is
added.

=item * B<medium>

These photos are scaled to 500 pixels at the longest dimension. A B<_m>
extension is added.

=item * B<square>

These photos are to cropped to 75 x 75 pixels at the center. A B<_s>
extension is added.

=back

=back

=item * B<fetch_medium>

Boolean.

Retrieve the "medium" version of a photo from the Flickr servers; these photos
have been scaled to 500 pixels at the longest dimension. 

Default is false.

=item * B<fetch_square>

Boolean.

Retrieve the "square" version of a photo from the Flickr servers; these photos
have been cropped to 75 x 75 pixels at the center.

Default is false.

=item * B<scrub_backups>

Boolean.

If true then, for each Flickr photo ID backed up, the library will check
B<backup.photos_root> for images (and metadata files) with a matching ID but
a different name. Matches will be deleted.

=item * B<force>

Boolean.

Force a photograph to be backed up even if it has not changed.

Default is false.

=back

=head2 rdf

=over 4

=item * B<do_dump>

Boolean.

Generate an RDF description for each photograph. Descriptions
are written to disk in separate files.

Default is false.

=item * B<rdfdump_root>

String.

The path where RDF data dumps for a photo should be written. The default
is the same path as B<backup.photos_root>.

File names are generated with the same pattern used to name
photographs.

=item * B<photos_alias>

String.

If defined this string is applied as regular expression substitution to
B<backup.photos_root>.

Default is to append the B<file:/> URI protocol to a path.

=back

=head2 search

Any valid parameter that can be passed to the I<flickr.photos.search>
method B<except> 'user_id' which is pre-filled with the user_id that
corresponds to the B<flickr.auth_token> token.

=cut

use utf8;
use Encode;
use English;

use Config::Simple;

use Flickr::API;
use Flickr::API::Request;

use Date::Format;
use Date::Parse;

use Text::Unidecode;

use RDF::Simple::Parser;
use RDF::Simple::Serialiser;

use File::Basename;
use File::Path;
use File::Spec;
use File::Find::Rule;

use DirHandle;

use IO::AtomicFile;
use LWP::Simple;

use Log::Dispatch;
use Log::Dispatch::Screen;

use constant PAUSE_SECONDS_OK          => 2;
use constant PAUSE_SECONDS_UNAVAILABLE => 4;
use constant PAUSE_MAXTRIES            => 10;
use constant PAUSE_ONSTATUS            => 503;

use constant RDFMAP => {
    'EXIF' => {
          '41483' => 'flashEnergy',
          '33437' => 'fNumber',
          '37378' => 'apertureValue',
          '37520' => 'subsecTime',
          '34855' => 'isoSpeedRatings',
          '41484' => 'spatialFrequencyResponse',
          '37380' => 'exposureBiasValue',
          '532'   => 'referenceBlackWhite',
          '40964' => 'relatedSoundFile',
          '36868' => 'dateTimeDigitized',
          '34850' => 'exposureProgram',
          '272'   => 'model',
          '259'   => 'compression',
          '37381' => 'maxApertureValue',
          '37396' => 'subjectArea',
          '277'   => 'samplesPerPixel',
          '37121' => 'componentsConfiguration',
          '37377' => 'shutterSpeedValue',
          '37384' => 'lightSource',
          '41989' => 'focalLengthIn35mmFilm',
          '41495' => 'sensingMethod',
          '37386' => 'focalLength',
          '529'   => 'yCbCrCoefficients',
          '41488' => 'focalPlaneResolutionUnit',
          '37379' => 'brightnessValue',
          '41730' => 'cfaPattern',
          '41486' => 'focalPlaneXResolution',
          '37510' => 'userComment',
          '41992' => 'contrast',
          '41729' => 'sceneType',
          '41990' => 'sceneCaptureType',
          '41487' => 'focalPlaneYResolution',
          '37122' => 'compressedBitsPerPixel',
          '37385' => 'flash',
          '258'   => 'bitsPerSample',
          '530'   => 'yCbCrSubSampling',
          '41993' => 'saturation',
          '284'   => 'planarConfiguration',
          '41996' => 'subjectDistanceRange',
          '41987' => 'whiteBalance',
          '274'   => 'orientation',
          '40962' => 'pixelXDimension',
          '306'   => 'dateTime',
          '41493' => 'exposureIndex',
          '40963' => 'pixelYDimension',
          '41994' => 'sharpness',
          '315'   => 'artist',
          '1'     => 'interoperabilityIndex',
          '37383' => 'meteringMode',
          '37522' => 'subsecTimeDigitized',
          '42016' => 'imageUniqueId',
          '41728' => 'fileSource',
          '41991' => 'gainControl',
          '283'   => 'yResolution',
          '37500' => 'makerNote',
          '273'   => 'stripOffsets',
          '305'   => 'software',
          '531'   => 'yCbCrPositioning',
          '319'   => 'primaryChromaticities',
          '278'   => 'rowsPerStrip',
          '36864' => 'version',
          '34856' => 'oecf',
          '271'   => 'make',
          '282'   => 'xResolution',
          '37521' => 'subsecTimeOriginal',
          '262'   => 'photometricInterpretation',
          '40961' => 'colorSpace',
          '33434' => 'exposureTime',
          '33432' => 'copyright',
          '41995' => 'deviceSettingDescription',
          '318'   => 'whitePoint',
          '257'   => 'imageLength',
          '41988' => 'digitalZoomRatio',
          '301'   => 'transferFunction',
          '41985' => 'customRendered',
          '37382' => 'subjectDistance',
          '34852' => 'spectralSensitivity',
          '41492' => 'subjectLocation',
          '279'   => 'stripByteCounts',
          '296'   => 'resolutionUnit',
          '41986' => 'exposureMode',
          '40960' => 'flashpixVersion',
          '256'   => 'imageWidth',
          '36867' => 'dateTimeOriginal',
          '270'   => 'imageDescription',
      },
    
    GPS => {
	'11' => 'dop',
	'21' => 'destLongitudeRef',
	'7'  => 'timeStamp',
	'26' => 'destDistance',
	'17' => 'imgDirection',
	'2'  => 'latitude',
	'22' => 'destLongitude',
	'1'  => 'latitudeRef',
	'18' => 'mapDatum',
	'0'  => 'versionId',
	'30' => 'differential',
	'23' => 'destBearingRef',
	'16' => 'imgDirectionRef',
	'13' => 'speed',
	'29' => 'dateStamp',
	'27' => 'processingMethod',
	'25' => 'destDistanceRef',
	'6'  => 'altitude',
	'28' => 'arealInformation',
	'3'  => 'longitudeRef',
	'9'  => 'status',
	'12' => 'speedRef',
	'20' => 'destLatitude',
	'14' => 'trackRef',
	'15' => 'track',
	'8'  => 'satellites',
	'4'  => 'longitude',
	'24' => 'destBearing',
	'19' => 'destLatitudeRef',
	'10' => 'measureMode',
	'5'  => 'altitudeRef',
    },

    # TIFF => {},
};

# Because I am always too lazy to remember how to
# dereference a constant hash ref in order to loop
# over the keys. I will get to it ... someday.

my %sizes = ('Original' => '',
	     'Medium'   => '_m',
	     'Square'   => '_s');

=head1 PACKAGE METHODS

=cut

=head2 __PACKAGE__->new($cfg)

Returns a I<Net::Flickr::Backup> object.

=cut

sub new {
    my $pkg = shift;
    my $cfg = shift;

    my $self = {'__wait'   => time() + PAUSE_SECONDS_OK,
		'__paused' => 0};

    bless $self,$pkg;

    if (! $self->init($cfg)) {
	unself $self;
    }

    return $self;
}

sub init {
    my $self = shift;
    my $cfg  = shift;

    $self->{cfg} = (UNIVERSAL::isa($cfg,"Config::Simple")) ? $cfg : Config::Simple->new($cfg);

    #

    my $log_fmt = sub {
	my %args = @_;

	my $msg = $args{'message'};
	chomp $msg;

	if ($args{'level'} eq "error") {

	    my ($ln,$sub) = (caller(4))[2,3];
	    $sub =~ s/.*:://;

	    return sprintf("[%s][%s, ln%d] %s\n",
			   $args{'level'},$sub,$ln,$msg);
	}
	
	return sprintf("[%s] %s\n",$args{'level'},$msg);
    };

    my $logger = Log::Dispatch->new(callbacks=>$log_fmt);
    my $error  = Log::Dispatch::Screen->new(name      => '__error',
                                            min_level => 'error',
                                            stderr    => 1);

    $logger->add($error);
    $self->{'__logger'} = $logger;

    #

    $self->{api} = Flickr::API->new({key    => $self->{cfg}->param("flickr.api_key"),
				     secret => $self->{cfg}->param("flickr.api_secret")});
  
    $self->{api}->agent("Net::Flickr::Backup/1.2");
    return 1;
}

=head2 $obj->log()

Returns a I<Log::Dispatch> object.

=cut

sub log {
    my $self = shift;
    return $self->{'__logger'};
}

=head2 $obj->backup()

Returns true or false.

=cut

sub backup {
    my $self = shift;
    my $args = shift;

    my $photos_root = $self->{cfg}->param("backup.photos_root");
    my $force       = $self->{cfg}->param("backup.force");
    
    if (! $photos_root) {
	$self->log()->error("no photo root defined, exiting");
	return 0;
    }

    #

    my %cc    = (""  => "All rights reserved.",
		 "0" => "All rights reserved.");

    my %users = ();

    #

    my $auth = $self->_apicall({"method" => "flickr.auth.checkToken"});

    if (! $auth) {
	return 0;
    }

    my $nsid = $auth->findvalue("/rsp/auth/user/\@nsid");

    # RDF

    my $do_rdf   = $self->{cfg}->param("rdf.do_dump");
    my $rdf_root = $self->{cfg}->param("rdf.rdfdump_root");

    if (($do_rdf) && (! $rdf_root)) {
	$rdf_root = $photos_root;
    }

    # licensing 

    if ($do_rdf) {
    
	my $licenses = $self->_apicall({"method" => "flickr.photos.licenses.getInfo"});
	
	if (! $licenses) {
	    return 0;
	}

	foreach my $l ($licenses->findnodes("/rsp/licenses/license")) {
	    $cc{ $l->getAttribute("id") } = $l->getAttribute("url");
	}
    }

    #

    my $search = $self->{cfg}->param(-block=>"search");
    $search->{user_id} = $nsid;

    my $num_pages    = 0;
    my $current_page = 1;

    my $poll = 1;

    while ($poll) {

	$search->{page} = $current_page;
	# $search->{per_page} = 50;

	#

	my $photos = $self->_apicall({"method" => "flickr.photos.search",
				      args     => $search});

	if (! $photos) {
	    return 0;
	}

	$num_pages = $photos->findvalue("/rsp/photos/\@pages");

	#

	foreach my $node ($photos->findnodes("/rsp/photos/photo")) {

	    my $id      = $node->getAttribute("id");
	    my $secret  = $node->getAttribute("secret");

	    $self->log()->info(sprintf("process image %d (%s)",
				       $id,$node->getAttribute("title")));

	    $self->{'_scrub'}->{$id} = [];

	    #

	    my %local_users = ();

	    my $info = $self->_apicall({method=>"flickr.photos.getInfo",
					args=>{photo_id => $id,
					       secret   => $secret}});
	    
	    if (! $info) {
		next;
	    }

	    my $img = ($info->findnodes("/rsp/photo"))[0];

	    if (! $img) {
		next;
	    }

	    my $dates = ($img->findnodes("dates"))[0];
	    
	    my $last_update = $dates->getAttribute("lastupdate");
	    my $has_changed = 1;

	    #
	    
	    my %data = (photo_id => $id,
			user_id  => $nsid,
			title    => $img->find("title")->string_value(),
			taken    => $dates->getAttribute("taken"),
			posted   => $dates->getAttribute("posted"),
			lastmod  => $last_update);

	    my %files = ();

	    #
	    
	    my $title = &_clean(lc($data{title})) || "untitled";
	    my $dt    = $data{taken};
	    
	    $dt =~ /^(\d{4})-(\d{2})-(\d{2})/;
	    my ($yyyy,$mm,$dd) = ($1,$2,$3);

	    #

	    my $sizes = $self->_apicall({method => "flickr.photos.getSizes",
					 args   => {photo_id => $id}});

	    if (! $sizes) {
		next;
	    }

	    foreach my $label (keys %sizes) {

		unless ($label eq "Original") {
		    my $fetch_param = sprintf("backup.fetch_%s",lc($label));
		    
		    if (! $self->{cfg}->param($fetch_param)) {
			$self->log()->debug("$fetch_param config option is false, skipping");
			next;
		    }
		}

		#

		my $orig = ($sizes->findnodes("/rsp/sizes/size[\@label='$label']"))[0];

		if (! $orig) {
		    $self->log()->warning("Unable to locate size info for key $label\n");
		    next;
		}

		my $source  = $orig->getAttribute("source");
	    		
		my $img_root  = File::Spec->catdir($photos_root,$yyyy,$mm,$dd);
		my $img_fname = sprintf("%04d%02d%02d-%d-%s%s.jpg",$yyyy,$mm,$dd,$id,$title,$sizes{$label});

		push @{$self->{'_scrub'}->{$id}}, $img_fname;

		my $img_bak = File::Spec->catfile($img_root,$img_fname);

		#

		if (! $force) {
		    if (! $has_changed) {
			$self->log()->info("$img_bak has not changed, skipping\n");
			next;
		    }
		    
		    my $mtime = (stat($img_bak))[9];
		    
		    if ((-f $img_bak) && ($last_update) && ($mtime >= $last_update)) {
			$self->log()->info("$img_bak has not changed ($mtime/$last_update), skipping\n");
			$has_changed = 0;
			next;
		    }
		}

		#

		if (! -d $img_root) {

		    $self->log()->info("create $img_root");

		    if (! mkpath([$img_root],0,0755)) {
			$self->log()->error("failed to create $img_root, $!");
			next;
		    }
		}
		
		if (! getstore($source,$img_bak)) {
		    $self->log()->error("failed to store '$source' as '$img_bak', $!\n");
		    next;
		}

		$self->log()->info("stored $img_bak");

		#

		$files{$sizes{$label}} = {height => $orig->getAttribute("height"),
					  width  => $orig->getAttribute("width"),
					  path   => $img_bak};
	    }

	    #
	    
	    if (! $do_rdf) {
		next;
	    }

	    my $meta_root  = File::Spec->catdir($rdf_root,$yyyy,$mm,$dd);
	    my $meta_fname = sprintf("%04d%02d%02d-%d-%s.xml",$yyyy,$mm,$dd,$id,$title);	
	    my $meta_bak   = File::Spec->catfile($meta_root,$meta_fname);

	    if ((! $force) && (! $has_changed) && (-f $meta_bak)) {
		next;
	    }

	    #

	    $data{license} = $cc{$img->getAttribute("license")};

	    #

	    my $exif = $self->_apicall({method=>"flickr.photos.getExif",
					args=>{photo_id => $id,
					       secret   => $secret}});

	    if ($exif) {
		foreach my $tag ($exif->findnodes("/rsp/photo/exif[\@tagspace='EXIF']")) {

		    my $facet   = $tag->getAttribute("tagspace");
		    my $tag_dec = $tag->getAttribute("tag");
		    my $value   = $tag->findvalue("clean") || $tag->findvalue("raw");
		    $data{exif}->{$facet}->{$tag_dec} = $value;
		}
	    }

	    #
	    
	    $data{desc}   = $img->find("descrption")->string_value();
	    
	    my $owner     = ($img->findnodes("owner"))[0];
	    my $owner_id  = $owner->getAttribute("nsid");
	    
	    $data{owner_id} = $owner_id;

	    if (! $users{$owner_id}) {
		$users{$owner_id} = $self->get_user($owner_id);
	    }

	    $local_users{$owner_id} = $users{$owner_id};

	    #

	    my $vis = ($img->findnodes("visibility"))[0];
	    
	    if ($vis->getAttribute("ispublic")) {
		$data{visibility} = "public";
	    }
	    
	    elsif (($vis->getAttribute("isfamily")) && ($vis->getAttribute("isfriend"))) {
		$data{visibility} = "family;friend";
	    }
	    
	    elsif ($vis->getAttribute("isfamily")) {
		$data{visibility} = "family";
	    }
	    
	    elsif ($vis->getAttribute("is_friend")) {
		$data{visibility} = "friend";
	    }
	    
	    else {
		$data{visibility} = "private";
	    }
	    
	    #
	    
	    foreach my $tag ($img->findnodes("tags/tag")) {
		
		my $id     = $tag->getAttribute("id");
		my $raw    = $tag->getAttribute("raw");
		my $clean  = $tag->string_value();
		my $author = $tag->getAttribute("author");
		
		$data{tags}->{$id} = [$clean,$raw,$author];
		$data{tag_map}->{$clean}->{$raw} ++;

		if (! $users{$author}) {
		    $users{$author} = $self->get_user($author);		
		}

		$local_users{$author} = $users{$author};
	    }
	    
	    #
	    
	    foreach my $note ($img->findnodes("notes/note")) {
		
		$data{notes} ||= [];
		
		my %note = map {
		    $_ => $note->getAttribute($_);
		} qw (x y h w id author authorname);
		
		$note{body} = $note->string_value();
		push @{$data{notes}}, \%note;

		if (! $users{$note{author}}) {
		    $users{$note{author}} = $self->get_user($note{author});		
		}

		$local_users{$note{author}} = $users{$note{author}};
	    }
	    	   	            
	    #
	    
	    push @{$self->{'_scrub'}->{$id}}, $meta_bak;

	    my $fh = IO::AtomicFile->open($meta_bak,"w");
	    binmode($fh);

	    if (! $fh) {
		$self->log()->error("failed to open '$meta_bak' for writing, $!\n");
		next;
	    }
	    
	    $fh->print("<?xml version = \"1.0\" encoding = \"UTF-8\" ?>\n");

	    if (my $xsl = $self->{cfg}->param("rdf.xsl_stylesheet")) {
		$fh->print("<?xml-stylesheet href = \"$xsl\" type = \"text/xsl\" ?>\n");
	    }

	    $fh->print($self->make_rdf(\%files,\%data,\%local_users));

	    if (! $fh->close()) {
		$self->log()->error("failed to write '$meta_bak', $!");
	    }
	}

	if ($current_page == $num_pages) {
	    $poll = 0;
	}

	$current_page ++;
    }

    #

    if ($self->{cfg}->param("backup.scrub_backups")) {
	$self->log()->info("scrubbing backups");
	$self->scrub();
    }

    return 1;
}

sub make_rdf {
    my $self  = shift;
    my $files = shift;
    my $data  = shift;
    my $users = shift;

    my $photo = sprintf("http://www.flickr.com/photos/%s/%d",$data->{user_id},$data->{photo_id});

    #

    my $ser = RDF::Simple::Serialiser->new();

    $ser->addns("dc","http://purl.org/dc/elements/1.1/");
    $ser->addns("exif","http://nwalsh.com/rdf/exif#");
    $ser->addns("exifi","http://nwalsh.com/rdf/exif-intrinsic#");
    $ser->addns("a","http://www.w3.org/2000/10/annotation-ns");
    $ser->addns("rdfs","http://www.w3.org/2000/01/rdf-schema#");
    $ser->addns("i","http://www.w3.org/2004/02/image-regions#");
    $ser->addns("foaf","http://xmlns.com/foaf/0.1/#");
    $ser->addns("geo","http://www.w3.org/2003/01/geo/wgs84_pos#");
    $ser->addns("acl","http://www.w3.org/2001/02/acls#");
    $ser->addns("skos","http://www.w3.org/2004/02/skos/core#");

    my @triples = ();

    #

    my $user_root = "http://www.flickr.com/people/";
    my $tag_root  = "http://www.flickr.com/photos/tags/";

    # the document on the local filesystem

    my $alias = $self->{cfg}->param("rdf.photos_alias");
    my $root  = $self->{cfg}->param("backup.photos_root");

    foreach my $label (keys %$files) {
	my $source = $files->{$label}->{path};

	if (-f $source) {

	    my $local_file = undef;

	    if ($alias) {
		$local_file = $source;
		$local_file =~ s/$root/$alias/;
	    }

	    else {
		# Oh right, patch RDF::Simple...
		$local_file = "file://$source";
	    }

	    #

	    push @triples, [$local_file,"rdfs:seeAlso",$photo];
	    push @triples, [$local_file,"dc:created",time2str("%Y-%m-%dT%H:%M:%S%z",(stat($source))[9])];
	    push @triples, [$local_file,"dc:creator",(getpwuid($EUID))[0]];

	    push @triples, [$local_file,"exifi:height",$files->{$label}->{height}];
	    push @triples, [$local_file,"exifi:width",$files->{$label}->{width}];
	}
    }

    # flickr data

    push @triples, [$photo,"rdfs:type","http://purl.org/dc/dcmitype/StillImage"];
    push @triples, [$photo,"dc:creator",sprintf("%s%s",$user_root,$data->{user_id})];
    push @triples, [$photo,"dc:title",$data->{title}];
    push @triples, [$photo,"dc:description",$data->{desc}];
    push @triples, [$photo,"dc:created",time2str("%Y-%m-%dT%H:%M:%S%z",str2time($data->{taken}))];
    push @triples, [$photo,"dc:dateSubmitted",time2str("%Y-%m-%dT%H:%M:%S%z",$data->{posted})];
    push @triples, [$photo,"acl:accessor",$data->{visibility}];
    push @triples, [$photo,"acl:access","visbility"];

    # geo data

    if (($data->{lat}) && ($data->{long})) {
	push @triples, [$photo,"geo:lat",$data->{lat}];
	push @triples, [$photo,"geo:long",$data->{long}];
	push @triples, [$photo,"dc:coverage",$data->{coverage}];
    }

    # licensing
 
    push @triples, [$photo,"dc:rights",$data->{license}];

    # tags

     if (exists($data->{tags})) {

	foreach my $id (keys %{$data->{tags}}) {

	    my $parts  = $data->{tags}->{$id};

	    my $clean  = $parts->[0];
	    my $raw    = $parts->[1];
	    my $author = $parts->[2];

	    my $tag_uri    = "http://flickr.com/photos/tags/$clean#$id";
	    my $author_uri = sprintf("%s%s",$user_root,$author);
	    my $clean_uri  = sprintf("%s%s",$tag_root,$clean);

	    #

	    push @triples, [$photo,"dc:subject",$tag_uri];

	    push @triples, [$tag_uri,"rdfs:type","http://www.w3.org/2004/02/skos/core#Concept"];
	    push @triples, [$tag_uri,"skos:prefLabel",$raw];
	    push @triples, [$tag_uri,"skos:altLabel",$clean];
	    push @triples, [$tag_uri,"dc:creator",$author_uri];
	}
    }

    # notes/annotations

    if (exists($data->{notes})) {

	foreach my $n (@{$data->{notes}}) {

	    my $note       = "$photo#note-$n->{id}";
	    my $author_uri = sprintf("%s%s",$user_root,$n->{author});

	    push @triples, [$photo,"a:hasAnnotation",$note];

	    push @triples, [$note,"a:annotates",$photo];
	    push @triples, [$note,"a:author",$author_uri];
	    push @triples, [$note,"a:body",$n->{body}];
	    push @triples, [$note,"i:boundingBox", "$n->{x} $n->{y} $n->{w} $n->{h}"];
	    push @triples, [$note,"rdfs:type","http://purl.org/dc/dcmitype/Text"];
	}
    }

    # users (authors)

    foreach my $user (keys %{$users}) {

	my $uri   = sprintf("%s%s",$user_root,$user);
	my $parts = $users->{$user};

	push @triples, [$uri,"foaf:nick",$parts->{username}];
	push @triples, [$uri,"foaf:name",$parts->{realname}];
	push @triples, [$uri,"foaf:mbox_sha1sum",$parts->{mbox_sha1sum}];
	push @triples, [$uri,"rdfs:type","http://xmlns.com/foaf/0.1/Person"];
    }

    # comments (can't do those yet)

    # EXIF data

    foreach my $facet (keys %{$data->{exif}}) {

	if (! exists(RDFMAP->{$facet})) {
	    next;
	}

	foreach my $tag (keys %{$data->{exif}->{$facet}}) {

	    my $label = RDFMAP->{$facet}->{$tag};

	    if (! $label) {
		print "[err] can't find any label for $facet tag : $tag\n";
		next;
	    }

	    my $value = $data->{exif}->{$facet}->{$tag};

	    # Requires patched RDF::Simple to prevent
	    # W3CDTF from being interpreted as a resource

	    push @triples, [$photo, "exif:$label", "$value"];
	}
    }

    #

    return $ser->serialise(@triples);
}

sub scrub {
    my $self = shift;

    if (! keys %{$self->{'_scrub'}}) {
	return 1;
    }

    #

    my $rule = File::Find::Rule->new();
    $rule->file();
    
    $rule->exec(sub {
	my ($shortname, $path, $fullname) = @_;

	# print "test $shortname\n";

	$shortname =~ /^\d{8}-(\d+)-/;
	my $id = $1;

	if (! exists($self->{'_scrub'}->{$id})) {
	    return 0;
	}
	
	if (grep/$shortname/,@{$self->{'_scrub'}->{$id}}) {
	    return 0;
	}
	
	return 1;
    });

    #

    foreach my $path ($rule->in($self->{'cfg'}->param("backup.photos_root"))) {

	if (! unlink($path)) {
	    $self->log()->error("failed to unlink $path, $!");
	    next;
	}

	# next unlink empty parent directories

	my $dd_dir   = dirname($path);
	my $mm_dir   = dirname($dd_dir);
	my $yyyy_dir = dirname($mm_dir);

	foreach my $path ($dd_dir,$mm_dir,$yyyy_dir) {
	    if (&_has_children($path)) {
		last;
	    }

	    else {
		if (! rmtree([$path],0,1)) {
		    $self->log()->error("failed to unlink, $path");
		    last;
		}
	    }
	}	
    }

    #

    $self->{'_scrub'} = {};
    return 1;
}

sub get_user {
    my $self    = shift;
    my $user_id = shift;

    my %data = ();

    my $user = $self->_apicall({method => "flickr.people.getInfo",
				args   => {user_id=> $user_id}});
    
    if ($user) {
	foreach my $prop ("username", "realname", "mbox_sha1sum") {
	    $data{$prop} = $user->findvalue("/rsp/person/$prop");
	}
    }

    return \%data;
}

sub _apicall {
    my $self = shift;
    my $args = shift;

    #

    # check to see if we need to take
    # breather (are we pounding or are
    # we not?)

    while (time < $self->{'__wait'}) {

	my $debug_msg = sprintf("trying not to beat up the Flickr servers, pause for %.2f seconds\n",
				PAUSE_SECONDS_OK);

	$self->log()->debug($debug_msg);
	sleep(PAUSE_SECONDS_OK);
    }

    # send request

    delete $args->{args}->{api_sig};
    $args->{args}->{auth_token} = $self->{cfg}->param("flickr.auth_token");

    my $req = Flickr::API::Request->new($args);
    $self->log()->debug("calling $args->{method}");

    my $res = $self->{api}->execute_request($req);

    # check for 503 status

    if ($res->code() eq PAUSE_ONSTATUS) {

	# you are in a dark and twisty corridor
	# where all the errors look the same - 
	# just give up if we hit this ceiling

	$self->{'__paused'} ++;

	if ($self->{'__paused'} > PAUSE_MAXTRIES) {

	    my $errmsg = sprintf("service returned '%d' status %d times; exiting",
				 PAUSE_ONSTATUS,PAUSE_MAXTRIES);
	    
	    $self->log()->error($errmsg);
	    return undef;
	}

	my $retry_after = $res->header("Retry-After");
	my $debug_msg   = undef;

	if ($retry_after ) {
	    $debug_msg = sprintf("service unavailable, requested to retry in %d seconds",
				 $retry_after);
	} 

	else {
	    $retry_after = PAUSE_SECONDS_UNAVAILABLE * $self->{'__paused'};
	    $debug_msg = sprintf("service unavailable, pause for %.2f seconds",
				 $retry_after);
	}

	$self->log()->debug($debug_msg);
	sleep($retry_after);

	# try, try again

	return $self->_apicall($args);
    }

    $self->{'__wait'}   = time + PAUSE_SECONDS_OK;
    $self->{'__paused'} = 0;

    #

    my $xml = undef;
    eval "require XML::LibXML";

    if ($@) {

	eval {
	    eval "require XML::XPath";
	    $xml = XML::XPath->new(xml=>$res->content());
	};

    }

    else {
	eval {
	    my $parser = XML::LibXML->new();
	    $xml = $parser->parse_string($res->content());
	};
    }

    #

    if (! $xml) {
	$self->log()->error("failed to parse API response, calling $args->{method} : $@");
	$self->log()->error($res->content());
	return undef;
    }

    #

    if ($xml->findvalue("/rsp/\@stat") eq "fail") {
	$self->log()->error(sprintf("[%s] %s (calling calling $args->{method})\n",
				    $xml->findvalue("/rsp/err/\@code"),
				    $xml->findvalue("/rsp/err/\@msg")));
	return undef;
    }

    return ($@) ? undef : $xml;
}

sub _clean {
    my $str = shift;

    $str =~ s/\.jpg$//;

    # unidecode to convert everything to
    # happy happy ASCII
    
    # see also : http://perladvent.org/2004/12th/

    $str = unidecode(&_unescape(&_decode($str)));

    $str =~ s/@/at/g;
    $str =~ s/&/and/g;
    $str =~ s/\*/star/g;

    $str =~ s/[^a-z0-9\.\[\]-_]/ /ig;
    $str =~ s/'//g;

    # make all whitespace single spaces
    $str =~ s/\s+/ /g;

    # remove starting or trailing whitespace
    $str =~ s/^\s+//;
    $str =~ s/\s+$//;

    # make all spaces underscores
    $str =~ s/ /_/g;

    return $str;
}

sub _decode {
    my $str = shift;

    $str =~ s/(?:%([a-fA-F0-9]{2})%([a-fA-F0-9]{2}))/pack("U0U*",hex($1),hex($2))/eg;

    return decode_utf8($str);
}

# Borrowed from URI::Escape

sub _unescape {
    my $str = shift;

    if (defined($str)) {
	$str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    }

    return $str;
}

sub _has_children {
    my $path = shift;
    my $dh = DirHandle->new($path);
    my $has = grep { $_ !~ /^\.+$/ } $dh->read();
    return $has;
}

=head1 RDF

This is an example of an RDF dump for a photograph backed up from Flickr :

 <?xml version = "1.0" encoding = "UTF-8" ?>
  <rdf:RDF
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:a="http://www.w3.org/2000/10/annotation-ns"
   xmlns:acl="http://www.w3.org/2001/02/acls#"
   xmlns:exif="http://nwalsh.com/rdf/exif#"
   xmlns:skos="http://www.w3.org/2004/02/skos/core#"
   xmlns:exifi="http://nwalsh.com/rdf/exif-intrinsic#"
   xmlns:foaf="http://xmlns.com/foaf/0.1/#"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
   xmlns:i="http://www.w3.org/2004/02/image-regions#"
  >

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528">
    <exif:isoSpeedRatings>1250</exif:isoSpeedRatings>
    <exif:apertureValue>336/100</exif:apertureValue>
    <exif:pixelYDimension>960</exif:pixelYDimension>
    <exif:focalLength>4.5 mm</exif:focalLength>
    <acl:access>visbility</acl:access>
    <exif:colorSpace>sRGB</exif:colorSpace>
    <exif:dateTimeOriginal>2005:08:02 18:12:19</exif:dateTimeOriginal>
    <dc:rights>All rights reserved.</dc:rights>
    <exif:shutterSpeedValue>4321/1000</exif:shutterSpeedValue>
    <dc:description></dc:description>
    <exif:exposureTime>0.05 sec (263/5260)</exif:exposureTime>
    <dc:created>2005-08-02T18:12:19-0700</dc:created>
    <dc:dateSubmitted>2005-08-02T18:16:20-0700</dc:dateSubmitted>
    <exif:gainControl>High gain up</exif:gainControl>
    <exif:flash>32</exif:flash>
    <exif:digitalZoomRatio>100/100</exif:digitalZoomRatio>
    <exif:pixelXDimension>1280</exif:pixelXDimension>
    <exif:dateTimeDigitized>2005:08:02 18:12:19</exif:dateTimeDigitized>
    <dc:title>20050802(007).jpg</dc:title>
    <exif:fNumber>f/3.2</exif:fNumber>
    <acl:accessor>public</acl:accessor>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dc:subject rdf:resource="http://flickr.com/photos/tags/sanfrancisco#102449778"/>
    <dc:subject rdf:resource="http://flickr.com/photos/tags/cameraphone#102449777"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140939"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140942"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140945"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140946"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140952"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142648"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142656"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1143239"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1148950"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/StillImage"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140942">
    <i:boundingBox>468 141 22 26</i:boundingBox>
    <a:body>*sigh*</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142656">
    <i:boundingBox>357 193 81 28</i:boundingBox>
    <a:body>eww!</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/32373682187@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/people/44124415257@N01">
    <foaf:mbox_sha1sum>4f6f211958d5217ef0d10f7f5cd9a69cd66f217e</foaf:mbox_sha1sum>
    <foaf:name>Karl Dubost</foaf:name>
    <foaf:nick>karlcow</foaf:nick>
    <rdfs:type rdf:resource="http://xmlns.com/foaf/0.1/Person"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140939">
    <i:boundingBox>326 181 97 25</i:boundingBox>
    <a:body>Did you see that this shirt makes me a beautiful breast?</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140952">
    <i:boundingBox>9 205 145 55</i:boundingBox>
    <a:body>Do you want my opinion? There's a love affair going on here… Anyway. Talking non sense. We all know Heather is committed to Flickr. She even only dresses at FlickrApparel. Did they say &amp;quot;No Logo&amp;quot;. Doh Dude.</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/people/34427469121@N01">
    <foaf:mbox_sha1sum>216d56f03517c68e527c5b970552a181980c4389</foaf:mbox_sha1sum>
    <foaf:name>George Oates</foaf:name>
    <foaf:nick>George</foaf:nick>
    <rdfs:type rdf:resource="http://xmlns.com/foaf/0.1/Person"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140946">
    <i:boundingBox>355 31 103 95</i:boundingBox>
    <a:body>(Yes… I love you heather, you are my dream star)</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1143239">
    <i:boundingBox>184 164 50 50</i:boundingBox>
    <a:body>Baaaaarp!</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/34427469121@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140945">
    <i:boundingBox>433 103 50 50</i:boundingBox>
    <a:body>(fuck… fuck…)</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://example.com/2005/08/02/20050802-30763528-20050802_007.jpg">
    <dc:creator>asc</dc:creator>
    <exifi:height>960</exifi:height>
    <exifi:width>1280</exifi:width>
    <dc:created>2005-08-03T20:47:50-0700</dc:created>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/people/32373682187@N01">
    <foaf:mbox_sha1sum>62bf10c8d5b56623226689b7be924c64dee5e94a</foaf:mbox_sha1sum>
    <foaf:name>heather powazek champ</foaf:name>
    <foaf:nick>heather</foaf:nick>
    <rdfs:type rdf:resource="http://xmlns.com/foaf/0.1/Person"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://flickr.com/photos/tags/sanfrancisco#102449778">
    <skos:prefLabel>san francisco</skos:prefLabel>
    <skos:altLabel>sanfrancisco</skos:altLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <rdfs:type rdf:resource="http://www.w3.org/2004/02/skos/core#Concept"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142648">
    <i:boundingBox>202 224 50 50</i:boundingBox>
    <a:body>dude! who did this?</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/32373682187@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://flickr.com/photos/tags/cameraphone#102449777">
    <skos:prefLabel>cameraphone</skos:prefLabel>
    <skos:altLabel>cameraphone</skos:altLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <rdfs:type rdf:resource="http://www.w3.org/2004/02/skos/core#Concept"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://example.com/2005/08/02/20050802-30763528-20050802_007_m.jpg">
    <dc:creator>asc</dc:creator>
    <exifi:height>375</exifi:height>
    <exifi:width>500</exifi:width>
    <dc:created>2005-08-03T20:47:47-0700</dc:created>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://example.com/2005/08/02/20050802-30763528-20050802_007_t.jpg">
    <dc:creator>asc</dc:creator>
    <exifi:height>75</exifi:height>
    <exifi:width>100</exifi:width>
    <dc:created>2005-08-03T20:47:47-0700</dc:created>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1148950">
    <i:boundingBox>342 197 28 33</i:boundingBox>
    <a:body>Is that just one big boob, or...?</a:body>
    <a:author rdf:resource="http://www.flickr.com/people/34427469121@N01"/>
    <rdfs:type rdf:resource="http://purl.org/dc/dcmitype/Text"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
  </rdf:Description>

  <rdf:Description rdf:about="http://www.flickr.com/people/35034348999@N01">
    <foaf:mbox_sha1sum>a4d1b5e38db5e2ed4f847f9f09fd51cf59bc0d3f</foaf:mbox_sha1sum>
    <foaf:name>Aaron</foaf:name>
    <foaf:nick>straup</foaf:nick>
    <rdfs:type rdf:resource="http://xmlns.com/foaf/0.1/Person"/>
  </rdf:Description>

 </rdf:RDF>

=head1 VERSION

1.2

=head1 DATE

$Date: 2005/09/01 22:41:33 $

=head1 AUTHOR

Aaron Straup Cope E<lt>ascope@cpan.orgE<gt>

=head1 TO DO 

Support for the Flickr API photos.getAllContexts method to record the groups,
sets, etc. to which a photo belongs.

=head1 SEE ALSO 

L<Flickr::API>

L<Config::Simple>

http://www.flickr.com/services/api/misc.userauth.html

=head1 BUGS

Please report all bugs via http://rt.cpan.org

=head1 LICENSE

Copyright (c) 2005 Aaron Straup Cope. All Rights Reserved.

This is free software. You may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

return 1;
