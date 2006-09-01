# $Id: Backup.pm,v 1.86 2006/09/01 15:56:17 asc Exp $
# -*-perl-*-

use strict;
use warnings;

package Net::Flickr::Backup;
use base qw (Net::Flickr::RDF);

$Net::Flickr::Backup::VERSION = '2.92';

=head1 NAME

Net::Flickr::Backup - OOP for backing up your Flickr photos locally

=head1 SYNOPSIS

    use Net::Flickr::Backup;
    use Log::Dispatch::Screen;
    
    my $flickr = Net::Flickr::Backup->new($cfg);

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

=item * B<fetch_original>

Boolean.

Retrieve the "original" version of a photo from the Flickr servers. 

Default is true.

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

=item * B<rdfdump_inline>

Boolean.

Set to true if you want the RDF dump for a photo to be stored in the file's
JPEG COM block. RDF data will only be stored (for the time being) in the original
image file and not any of the scaled versions.

This option will only work for JPEG files and is still B<experimental>. It may change
or, you know, not always work. Using Adobe's XMP spec is on the list of things to poke
at so if you've got any suggestions on the subject, they'd be welcome.

Default is false.

=item * B<photos_alias>

String.

If defined this string is applied as regular expression substitution to
B<backup.photos_root>.

Default is to append the B<file:/> URI protocol to a path.

=back

=head2 iptc

=over 4

=item * B<do_dump>

Boolean.

If true, then a limited set of metadata associated with a photo will be stored
as IPTC information.

A photo's title is stored as the IPTC B<Headline>, description as B<Caption/Abstract>
and tags are stored in one or more B<Keyword> headers. Per the IPTC 7901 spec,
all text is converted to the ISO-8859-1 character encoding. 

For example :

 exiv2 -pi /home/asc/photos/2006/06/20/20060620-171674319-mie.jpg
 Iptc.Application2.RecordVersion              Short       1  2
 Iptc.Application2.Keywords                   String     11  cameraphone
 Iptc.Application2.Keywords                   String     15  "san francisco"
 Iptc.Application2.Keywords                   String      5  filtr
 Iptc.Application2.Keywords                   String      3  mie
 Iptc.Application2.Keywords                   String     20  upcoming:event=77752
 Iptc.Application2.Headline                   String      3  Mie  

Default is false.

=back

=head2 search

Any valid parameter that can be passed to the I<flickr.photos.search>
method B<except> 'user_id' which is pre-filled with the user_id that
corresponds to the B<flickr.auth_token> token.

=head2 modified since

String.

This specifies a time-based limiting criteria for fetching photos.

The syntax is B<(n)(modifier)> where B<(n)> is a positive integer and B<(modifier)>
may be one of the following :

=over 4

=item * B<h>

Fetch photos that have been modified in the last B<(n)> hours.

=item * B<d>

Fetch photos that have been modified in the last B<(n)> days.

=item * B<w>

Fetch photos that have been modified in the last B<(n)> weeks.

=item * B<M>

Fetch photos that have been modified in the last B<(n)> months.

=back

=cut

use utf8;
use Encode;
use English;

use Text::Unidecode;

use File::Basename;
use File::Path;
use File::Spec;
use File::Find::Rule;

use DirHandle;

use IO::AtomicFile;
use IO::Scalar;
use LWP::Simple;

use Sys::Hostname::FQDN;
use Memoize;

Readonly::Hash my %FETCH_SIZES => ('Original' => '',
				   'Medium'   => '_m',
				   'Square'   => '_s');

Readonly::Scalar my $FLICKR_URL        => "http://www.flickr.com/";
Readonly::Scalar my $FLICKR_URL_PHOTOS => $FLICKR_URL . "photos/";				      

=head1 PACKAGE METHODS

=cut

=head2 __PACKAGE__->new($cfg)

Returns a I<Net::Flickr::Backup> object.

=cut

# Defined in Net::Flickr::API

sub init {
        my $self = shift;
        my $cfg  = shift;
        
        if (! $self->SUPER::init($cfg)) {
                return 0;
        }
        
        #
        # Ensure that we have 'flickr' and 'backup'
        # config blocks
        #

        foreach my $block ('flickr', 'backup') {
                
                my $test = $self->{cfg}->param(-block=>$block);
                
                if (! keys %$test) {
                        $self->log()->error("unable to find any properties for $block block in config file");
                        return 0;
                }
        }

        #

        $self->{'__callbacks'} = {};
        $self->{'__cancel'} = 0;

        #

        memoize("_clean");
        return 1;
}

=head1 OBJECTS METHODS YOU SHOULD CARE ABOUT

=cut

=head2 $obj->backup()

Returns true or false.

=cut

sub backup {
        my $self = shift;
        my $args = shift;
        
        my $auth = $self->_auth();
        
        if (! $auth) {
                return 0;
        }
        
        #
        #
        #

        my $photos_root = $self->{cfg}->param("backup.photos_root");
        
        if (! $photos_root) {
                $self->log()->error("no photo root defined, exiting");
                return 0;
        }
        
        #
        #
        #

        my $poll_meth = "flickr.photos.search";
        my $poll_args = $self->{cfg}->param(-block=>"search");

        $poll_args->{user_id} = $auth->findvalue("/rsp/auth/user/\@nsid");

        if (my $min_date = $self->{cfg}->param("search.modified_since")) {

                if ($min_date !~ /^\d+$/) {
                        $min_date = &_mk_mindate($min_date);

                        if (! $min_date) {
                                $self->log()->error("unable to parse min date criteria, exiting");
                                return 0;
                        }
                }

                $poll_meth = "flickr.photos.recentlyUpdated";
                $poll_args = {min_date => $min_date};
        }

        #
        #
        #

        my $num_pages    = 0;
        my $current_page = 1;
        
        my $poll = 1;
        
        while ($poll) {
                
                if ($self->{'__cancel'}) {
                        last;
                }

                $poll_args->{page} = $current_page;
                
                #
           
                my $photos = $self->api_call({"method" => $poll_meth,
                                              args     => $poll_args});
                
                if (! $photos) {
                        return 0;
                }

                #

                if (($current_page == 1) && ($self->_has_callback("start_backup_queue"))) {
                        $self->_execute_callback("start_backup_queue", $photos);
                }
                
                #

                $num_pages = $photos->findvalue("/rsp/photos/\@pages");
                
                #
                
                foreach my $node ($photos->findnodes("/rsp/photos/photo")) {
                        
                        if ($self->{'__cancel'}) {
                                last;
                        }

                        $self->{'__files'} = {};
                        
                        my $id      = $node->getAttribute("id");
                        my $secret  = $node->getAttribute("secret");
                        
                        $self->log()->info(sprintf("process image %d (%s)",
                                                   $id, &_clean($node->getAttribute("title"))));
                        
                        #

                        if ($self->_has_callback("start_backup_photo")) {
                                $self->_execute_callback("start_backup_photo", $node);
                        }
                        
                        my $ok = $self->backup_photo($id,$secret);

                        if ($self->_has_callback("finish_backup_photo")) {
                                $self->_execute_callback("finish_backup_photo", $node, $ok);
                        }

                }
                
                if ($current_page == $num_pages) {
                        $poll = 0;
                }
                
                $current_page ++;
        }
        
        #

        if ($self->_has_callback("finish_backup_queue")) {
                $self->_execute_callback("finish_backup_queue");
        }
        
        #
        
        if ((! $self->{'__cancel'}) && ($self->{cfg}->param("backup.scrub_backups"))) {
                $self->log()->info("scrubbing backups");
                $self->scrub();
        }
        
        return 1;
}

=head1 OBJECT METHODS YOU MAY CARE ABOUT

=cut

=head2 $obj->backup_photo($id,$secret)

Backup an individual photo. This method is called internally by
I<backup>.

=cut

sub backup_photo {
        my $self   = shift;
        my $id     = shift;
        my $secret = shift;
        
        if (! $self->_auth()) {
                return 0;
        }
        
        #
        
        my $force       = $self->{cfg}->param("backup.force");
        my $photos_root = $self->{cfg}->param("backup.photos_root");
        
        if (! $photos_root) {
                $self->log()->error("no photo root defined, exiting");
                return 0;
        }
                
        #
        
        my $info = $self->api_call({method=>"flickr.photos.getInfo",
                                    args=>{photo_id => $id,
                                           secret   => $secret}});
        
        if (! $info) {
                return 0;
        }
        
        $self->{'_scrub'}->{$id} = [];
        
        my $img = ($info->findnodes("/rsp/photo"))[0];
        
        if (! $img) {
                return 0;
        }
        
        my $dates = ($img->findnodes("dates"))[0];
        
        my $last_update = $dates->getAttribute("lastupdate");
        my $has_changed = 1;
        
        #
        
        my %data = (photo_id => $id,
                    user_id  => $img->findvalue("owner/\@nsid"),
                    title    => $img->find("title")->string_value(),
                    taken    => $dates->getAttribute("taken"),
                    posted   => $dates->getAttribute("posted"),
                    lastmod  => $last_update);
        
        #
        
        my $title = &_clean($data{title}) || "untitled";

        my $dt    = $data{taken};
        
        $dt =~ /^(\d{4})-(\d{2})-(\d{2})/;
        my ($yyyy,$mm,$dd) = ($1,$2,$3);	  	    
        
        #
        
        my $sizes = $self->api_call({method => "flickr.photos.getSizes",
                                     args   => {photo_id => $id}});
        
        if (! $sizes) {
                return 0;
        }
        
        #
        
        my $fetch_cfg = $self->{cfg}->param(-block=>"backup");
        
        foreach my $label (keys %FETCH_SIZES) {
                
                my $fetch_param = "fetch_".lc($label);
                my $do_fetch    = 1;
                
                if (($label ne "Original") || (exists($fetch_cfg->{$fetch_param}))) {
                        $do_fetch = $fetch_cfg->{$fetch_param};
                }
                
                if (! $do_fetch) {
                        $self->log()->debug("$fetch_param option is false, skipping");
                        next;
                }
                
                #
                
                my $sz = ($sizes->findnodes("/rsp/sizes/size[\@label='$label']"))[0];
                
                if (! $sz) {
                        $self->log()->warning("Unable to locate size info for key $label\n");
                        next;
                }
                
                my $source  = $sz->getAttribute("source");
                
                my $img_root  = File::Spec->catdir($photos_root, $yyyy, $mm, $dd);
                my $img_fname = sprintf("%04d%02d%02d-%d-%s%s.jpg", $yyyy, $mm, $dd, $id, $title, $FETCH_SIZES{$label});
                
                push @{$self->{'_scrub'}->{$id}}, $img_fname;
                
                my $img_bak = File::Spec->catfile($img_root, $img_fname);
                
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
                        
                        if (! mkpath([$img_root], 0, 0755)) {
                                $self->log()->error("failed to create $img_root, $!");
                                next;
                        }
                }
                
                if (! getstore($source, $img_bak)) {
                        $self->log()->error("failed to store '$source' as '$img_bak', $!\n");
                        next;
                }
                
                $self->log()->info("stored $img_bak");
                
                #
                
                $self->{'__files'}->{$label} = $img_bak;
        }
        
        if (! keys %{$self->{'__files'}}) {
                return 1;
        }

        #
        # Is that RDF in your pants?
        #

        if ($self->{cfg}->param("rdf.do_dump")) {
                $self->store_rdf($info, $has_changed, $force);
        }

        #
        # JPEG/IPTC
        #

        if ($self->{cfg}->param("iptc.do_dump")) {
                $self->store_iptc($info, $has_changed, $force);
        }

        return 1;
}

sub store_rdf {
        my $self        = shift;
        my $photo       = shift;
        my $has_changed = shift;
        my $force       = shift;

        my $rdf_root   = $self->{cfg}->param("rdf.rdfdump_root");
        my $rdf_inline = $self->{cfg}->param("rdf.rdfdump_inline");
        my $rdf_str    = "";

        if ((! $rdf_inline) && (! $rdf_root)) {
                $rdf_root = $self->{cfg}->param("backup.photos_root");
        }

        my $id     = $photo->findvalue("/rsp/photo/\@id");
        my $secret = $photo->findvalue("/rsp/photo/\@secret");
        my $title  = $photo->findvalue("/rsp/photo/title") || "untitled";
        $title     = &_clean($title);

        my $dt = $photo->findvalue("/rsp/photo/dates/\@taken");
        
        $dt =~ /^(\d{4})-(\d{2})-(\d{2})/;
        my ($yyyy,$mm,$dd) = ($1,$2,$3);	  	    

        my $meta_root  = File::Spec->catdir($rdf_root, $yyyy, $mm, $dd);
        my $meta_fname = sprintf("%04d%02d%02d-%d-%s.xml", $yyyy, $mm, $dd, $id, $title);	
        my $meta_bak   = File::Spec->catfile($meta_root, $meta_fname);
        my $meta_str   = "";

        if ((! $force) && (! $has_changed) && (! $rdf_inline) && (-f $meta_bak)) {
                return 1;
        }
        
        push @{$self->{'_scrub'}->{$id}}, $meta_bak;
        
        #
        #
        #

        if ((! -d $meta_root) && (! $rdf_inline)) {
                
                $self->log()->info("create $meta_root");
                
                if (! mkpath([$meta_root], 0, 0755)) {
                        $self->log()->error("failed to create $meta_root, $!");
                        next;
                }
	}
        
        #
        #
        #

        $self->log()->info("fetching RDF data for photo");
        
        my $fh = undef;

        if ($rdf_inline) {
                $fh = IO::Scalar->new(\$rdf_str);
        }

        else {
                $fh = IO::AtomicFile->open($meta_bak, "w");
        }

        if (! $fh) {
                $self->log()->error("failed to open '$meta_bak', $!");
                return 0;
        }
        
        #
        #
        #

        my $desc_ok = $self->describe_photo({photo_id => $id,
                                             secret   => $secret,
                                             fh       => \*$fh});
        
        if (! $desc_ok) {
                $self->log()->error("failed to describe photo $id:$secret\n");
                $fh->delete();
                return 0;
        }
        
        if (! $fh->close()) {
                $self->log()->error("failed to write '$meta_bak', $!");
                return 0;
        }

        #
        # JPEG/RDF COM
        #

        if ($rdf_inline) {
                if (! $self->store_rdf_inline(\$rdf_str, $self->{'__files'}->{'Original'})) {
                        return 0;
                }
        }

        return 1;
}

sub store_iptc {
        my $self = shift;
        my $photo       = shift;
        my $has_changed = shift;
        my $force       = shift;

        if ((! $has_changed) && (! $force)) {
                return 1;
        }

        return $self->store_iptc_inline($photo, $self->{'__files'}->{'Original'});
}

sub store_iptc_inline {
        my $self     = shift;
        my $photo    = shift;
        my $original = shift;

        my $im = $self->_jpeg_handler($original);

        if (! $im) {
                return 0;
        }

        my %iptc = ('Headline'         => $self->_iptcify($photo->findvalue("/rsp/photo/title")),
                    'Caption/Abstract' => $self->_iptcify($photo->findvalue("/rsp/photo/description")),
                    'Keywords'         => []);

        my @tags = ();

        foreach my $tag ($photo->findnodes("/rsp/photo/tags/tag")) {
                my $raw = $self->_iptcify($tag->getAttribute("raw"));

                if ($raw =~ /\s/) {
                        $raw = "\"$raw\"";
                }

                push @{$iptc{'Keywords'}}, $raw;
        }

        if (! $im->set_app13_data(\%iptc, 'UPDATE', 'IPTC')) {
                $self->log()->error("Failed to updated IPTC");
                return 0;
        }

        if (! $im->save($original)) {
                $self->log()->error("Failed store IPTC, $!");
                return 0;
        }

        return 1;
}

sub store_rdf_inline {
        my $self     = shift;
        my $str_rdf  = shift;
        my $path_jpg = shift;

        my $im = $self->_jpeg_handler($path_jpg, "COM");

        if (! $im) {
                return 0;
        }

        $im->add_comment($$str_rdf);

        if (! $im->save("$path_jpg")) {
                $self->log()->error("Failed store COM block, $!");
                return 0;
        }

        return 1;
}

=head2 $obj->scrub()

Returns true or false.

=cut

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
                         
                            if (! $id) {
                                    return 0;
                            }

                            if (! exists($self->{'_scrub'}->{$id})) {
                                    return 0;
                            }
                            
                            if (grep/$shortname/,@{$self->{'_scrub'}->{$id}}) {
                                    return 0;
                            }
                            
                            return 1;
                    });
        
        #
        
        foreach my $root ($rule->in($self->{'cfg'}->param("backup.photos_root"))) {
                
                if (! unlink($root)) {
                        $self->log()->error("failed to unlink $root, $!");
                        next;
                }
                
                # next unlink empty parent directories
                
                my $dd_dir   = dirname($root);
                my $mm_dir   = dirname($dd_dir);
                my $yyyy_dir = dirname($mm_dir);
                
                foreach my $path ($dd_dir, $mm_dir, $yyyy_dir) {
                        if (&_has_children($path)) {
                                last;
                        }
                        
                        else {
                                if (! rmtree([$path], 0, 1)) {
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

=head2 $obj->cancel_backup()

Cancel the backup process as soon as the current photo backup
is complete.

=cut

sub cancel_backup {
        my $self = shift;
        $self->{'__cancel'} = 1;
}

=head2 $obj->register_callback($name, \&func)

B<This method is still considered experimental and may be removed.>

Valid callback triggers are :

=over 4

=item * B<start_backup_queue>

The list of photos to be backed up is pulled from the Flickr servers
is done in batches. This trigger is invoked for the first successful
result set. 

The callback function will be passed a I<XML::XPath> representation
of the result document returned by the Flickr API.

=item * B<finish_backup_queue>

This trigger is invoked after the last photo has been backed up.

=item * B<start_backup_photo>

This trigger is invoked before the object's B<backup_photo> method is
called.

The callback function will be passed a I<XML::XPath> representation
of the current photo, as returned by the Flickr API.

=item * B<finish_backup_photo>

This trigger is invoked after the object's B<backup_photo> method is
called.

The callback function will be passed a I<XML::XPath> representation
of the current photo, as returned by the Flickr API, followed by a 
boolean indicating whether or not the backup was successful.

=back

Returns true or false, if I<$func> is not a valid code
reference.

=cut

sub register_callback {
        my $self = shift;
        my $name = shift;
        my $func = shift;

        if (ref($func) ne "CODE") {
                return 0;
        }

        $self->{'__callbacks'}->{$name} = $func;
        return 1;
}


=head2 $obj->namespaces()

Returns a hash ref of the prefixes and namespaces used by I<Net::Flickr::RDF>

The default key/value pairs are :

=over 4

=item B<a>

http://www.w3.org/2000/10/annotation-ns

=item B<acl>

http://www.w3.org/2001/02/acls#

=item B<dc>

http://purl.org/dc/elements/1.1/

=item B<dcterms>

http://purl.org/dc/terms/

=item B<exif>

http://nwalsh.com/rdf/exif#

=item B<exifi>

http://nwalsh.com/rdf/exif-intrinsic#

=item B<flickr>

x-urn:flickr:

=item B<foaf>

http://xmlns.com/foaf/0.1/#

=item B<geo> 

http://www.w3.org/2003/01/geo/wgs84_pos#

=item B<i>

http://www.w3.org/2004/02/image-regions#

=item B<rdf>

http://www.w3.org/1999/02/22-rdf-syntax-ns#

=item B<rdfs>

http://www.w3.org/2000/01/rdf-schema#

=item B<skos>

http://www.w3.org/2004/02/skos/core#

=back

I<Net::Flickr::Backup> adds the following namespaces :

=over 4

=item B<computer>

x-urn:B<$OSNAME>: (where $OSNAME is the value of the English.pm
$OSNAME variable.

=back

=cut

sub namespaces {
        my $self = shift;
        my %ns = %{$self->SUPER::namespaces()};
        $ns{computer} = sprintf("x-urn:%s:",$OSNAME);
        return (wantarray) ? %ns : \%ns;
}

=head2 $obj->namespace_prefix($uri)

Return the namespace prefix for I<$uri>

=cut

# Defined in Net::Flickr::RDF

=head2 $obj->uri_shortform($prefix,$name)

Returns a string in the form of I<prefix>:I<property>. The property is
the value of $name. The prefix passed may or may be the same as the prefix
returned depending on whether or not the user has defined or redefined their
own list of namespaces.

The prefix passed to the method is assumed to be one of prefixes in the
B<default> list of namespaces.

=cut

# Defined in Net::Flickr::RDF

=head2 $obj->make_photo_triples(\%data)

Returns an array ref of array refs of the meta data associated with a
photo (I<%data>).

If any errors are unencounter an error is recorded via the B<log>
method and the method returns undef.

=cut

sub make_photo_triples {
        my $self = shift;
        my $data = shift;
        
        my $triples = $self->SUPER::make_photo_triples($data);
        
        if (! $triples) {
                return undef;
        }
        
        my $user_id     = (getpwuid($EUID))[0];
        my $os_uri      = sprintf("x-urn:%s:",$OSNAME);
        my $user_uri    = $os_uri."user";
        
        my $creator_uri = sprintf("x-urn:%s#%s", Sys::Hostname::FQDN::short(), $user_id);
        
        push @$triples, [$user_uri, $self->uri_shortform("rdfs", "subClassOf"), "http://xmlns.com/foaf/0.1/Person"];
        
        foreach my $label (keys %{$self->{'__files'}}) {
                
                my $uri   = "file://".$self->{'__files'}->{$label};
                my $photo = sprintf("%s%s/%d", $FLICKR_URL_PHOTOS, $data->{user_id}, $data->{photo_id});
                
                push @$triples, [$uri, $self->uri_shortform("rdfs", "seeAlso"), $photo];
                push @$triples, [$uri, $self->uri_shortform("dc", "creator"), $creator_uri];
                push @$triples, [$uri, $self->uri_shortform("dcterms", "created"), &_w3cdtf()];
        }
        
        push @$triples, [$creator_uri, $self->uri_shortform("foaf", "name"), (getpwuid($EUID))[6]];
        push @$triples, [$creator_uri, $self->uri_shortform("foaf", "nick"), $user_id];
        push @$triples, [$creator_uri, $self->uri_shortform("rdf", "type"), "computer:user"];
        
        return $triples;
}

=head2 $obj->namespace_prefix($uri)

Return the namespace prefix for I<$uri>

=cut

=head2 $obj->uri_shortform($prefix,$name)

Returns a string in the form of I<prefix>:I<property>. The property is
the value of $name. The prefix passed may or may be the same as the prefix
returned depending on whether or not the user has defined or redefined their
own list of namespaces.

The prefix passed to the method is assumed to be one of prefixes in the
B<default> list of namespaces.

=cut

# Defined in Net::Flickr::RDF

=head2 $obj->api_call(\%args)

Valid args are :

=over 4

=item * B<method>

A string containing the name of the Flickr API method you are
calling.

=item * B<args>

A hash ref containing the key value pairs you are passing to 
I<method>

=back

If the method encounters any errors calling the API, receives an API error
or can not parse the response it will log an error event, via the B<log> method,
and return undef.

Otherwise it will return a I<XML::LibXML::Document> object (if XML::LibXML is
installed) or a I<XML::XPath> object.

=cut

# Defined in Net::Flickr::API

=head2 $obj->log()

Returns a I<Log::Dispatch> object.

=cut

# Defined in Net::Flickr::API

sub _auth {
        my $self = shift;
        
        if (! $self->{'__auth'}) {
                my $auth = $self->api_call({"method" => "flickr.auth.checkToken"});
                
                if (! $auth) {
                        return undef;
                }
                
                my $nsid = $auth->findvalue("/rsp/auth/user/\@nsid");
                
                if (! $nsid) {
                        $self->log()->error("unabled to determine ID for token");
                        return undef;
                }
                
                $self->{'__auth'} = $auth;
        }
        
        return $self->{'__auth'};
}

sub _clean {
        my $str = shift;
        
        $str = lc($str);
        
        $str =~ s/\.jpg$//;
        
        # unidecode to convert everything to
        # happy happy ASCII
        
        # see also : http://perladvent.org/2004/12th/
        
        $str = unidecode(&_unescape(&_decode($str)));
        
        $str =~ s/@/at/g;
        $str =~ s/&/and/g;
        $str =~ s/\*/star/g;
        
        $str =~ s/[^a-z0-9\[\]-_]/ /ig;
        $str =~ s/'//g;
        
        # make all whitespace single spaces
        $str =~ s/\s+/ /g;
        
        # remove starting or trailing whitespace
        $str =~ s/^\s+//;
        $str =~ s/\s+$//;

        # remove trailing periods
        $str =~ s/\.+$//;

        # make all spaces underscores
        $str =~ s/ /_/g;
        
        return $str;
}

sub _decode {
        my $str = shift;
        
        if (! utf8::is_utf8($str)) {
                $str = decode_utf8($str);
        }
        
        $str =~ s/(?:%([a-fA-F0-9]{2})%([a-fA-F0-9]{2}))/pack("U0U*", hex($1), hex($2))/eg;
        return $str;
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

# Borrowed from LWP::Authen::Wsse

sub _w3cdtf {
        my ($sec, $min, $hour, $mday, $mon, $year) = gmtime();
        $mon++; $year += 1900;
        
        return sprintf("%04s-%02s-%02sT%02s:%02s:%02sZ",
                       $year, $mon, $mday, $hour, $min, $sec);
}

sub _has_callback {
        my $self = shift;
        my $name = shift;

        my $cb = $self->{'__callbacks'};

        if (! exists($cb->{$name})) {
                return 0;
        }

        elsif (ref($cb->{$name} ne "CODE")) {
                return 0;
        }

        else {
                return 1;
        }
}

sub _execute_callback {
        my $self = shift;
        my $name = shift;
        $self->{'__callbacks'}->{$name}->(@_);
}

sub _mk_mindate {
        my $str = shift;
        
        $str =~ /^(\d+)([hdwM])$/;
        
        my $count  = $1;
        my $period = $2;
        
        # print "count $count : period $period\n";
        
        if ((! $count) || (! $period)) {
                return 0;
        }
        
        #
        
        if ($period eq "h") {
                return time() - ($count * (60 * 60));
        }
        
        elsif ($period eq "d") {
                return time() - ($count * (24 * (60 * 60)));
        }
        
        elsif ($period eq "w") {
                return time() - ($count * (7 * (24 * (60 * 60))));
        }
        
        elsif ($period eq "M") {
                return time() - ($count * (4 * (7 * (24 * (60 * 60)))));
        }
        
        else {
                return 0;
        }
}

sub _jpeg_handler {
        my $self = shift;
        my $img  = shift;

        eval "require Image::MetaData::JPEG";
        
        if ($@) {
                $self->log()->error("Failed to load Image::MetaData::JPEG, $@");
                return undef;
        }

        my $im = Image::MetaData::JPEG->new($img, @_);

        if (! $im) {
                $self->log()->error("Failed to read $img, " . Image::MetaData::JPEG::Error());
                return undef;
        }

        return $im;
}

sub _iptcify {
        my $self = shift;
        return encode("iso-8859-1", &_decode($_[0])); 
}

=head1 EXAMPLES

=cut

=head2 CONFIG FILES

This is an example of a Config::Simple file used to back up photos tagged
with 'cameraphone' from Flickr

 [flickr] 
 api_key=asd6234kjhdmbzcxi6e323
 api_secret=s00p3rs3k3t
 auth_token=123-omgwtf4u

 [search]
 tags=cameraphone
 per_page=500

 [backup]
 photos_root=/home/asc/photos
 scrub_backups=1
 fetch_medium=1
 fetch_square=1
 force=0

 [rdf]
 do_dump=1
 rdfdump_root=/home/asc/photos

=head2 RDF

This is an example of an RDF dump for a photograph backed up from Flickr :


 <?xml version='1.0'?>    
  <rdf:RDF
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:geo="http://www.w3.org/2003/01/geo/wgs84_pos#"
   xmlns:a="http://www.w3.org/2000/10/annotation-ns"
   xmlns:acl="http://www.w3.org/2001/02/acls#"
   xmlns:exif="http://nwalsh.com/rdf/exif#"
   xmlns:skos="http://www.w3.org/2004/02/skos/core#"
   xmlns:cc="http://web.resource.org/cc/"
   xmlns:foaf="http://xmlns.com/foaf/0.1/"
   xmlns:exifi="http://nwalsh.com/rdf/exif-intrinsic#"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
   xmlns:flickr="x-urn:flickr:"
   xmlns:dcterms="http://purl.org/dc/terms/"
   xmlns:i="http://www.w3.org/2004/02/image-regions#"
   >

   <flickr:photo rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528">
    <dc:description></dc:description>
    <geo:long>-122.417068</geo:long>
    <acl:access>visbility</acl:access>
    <geo:lat>37.7742</geo:lat>
    <dc:created>2005-08-02T18:12:19-0700</dc:created>
    <dc:title>20050802(007).jpg</dc:title>
    <acl:accessor>public</acl:accessor>
    <dc:dateSubmitted>2005-08-02T18:16:20-0700</dc:dateSubmitted>
    <cc:license rdf:resource="http://creativecommons.org/licenses/by-nd/2.0/"/>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/sanfrancisco"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/geolat377742"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/usa"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/california"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/geolong122417068"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/cameraphone"/>
    <dc:subject rdf:resource="http://www.flickr.com/photos/35034348999@N01/tags/geotagged"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/photos/35034348999@N01/sets/1082058"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/groups/97155967@N00/pool"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140939"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140942"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140945"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140946"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140952"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142648"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142656"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1143239"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#note-1148950"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/straup/30763528/#comment8400103"/>
    <a:hasAnnotation rdf:resource="http://www.flickr.com/photos/straup/30763528/#comment8399772"/>
   </flickr:photo>

   <dcterms:StillImage rdf:about="http://static.flickr.com/23/30763528_a981fab285_s.jpg">
    <dcterms:relation>Square</dcterms:relation>
    <exifi:height>75</exifi:height>
    <exifi:width>75</exifi:width>
    <dcterms:isVersionOf rdf:resource="http://static.flickr.com/23/30763528_a981fab285_o.jpg"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#exif"/>
   </dcterms:StillImage>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/california">
    <skos:prefLabel>california</skos:prefLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/california"/>
   </flickr:tag>

   <flickr:comment rdf:about="http://www.flickr.com/photos/straup/30763528/#comment8400103">
    <dc:identifier>6065-30763528-8400103</dc:identifier>
    <dc:created>2005-08-02T18:52:23</dc:created>
    <a:body>moooaahahaahahmooo</a:body>
    <dc:creator rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:comment>

   <flickr:user rdf:about="http://www.flickr.com/people/44124415257@N01">
    <foaf:mbox_sha1sum>b2310525591ca71b1cb9c2e3226dec1765d76c1e</foaf:mbox_sha1sum>
    <foaf:name></foaf:name>
    <foaf:nick>karlcow</foaf:nick>
   </flickr:user>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140939">
    <i:boundingBox>326 181 97 25</i:boundingBox>
    <a:body>Did you see that this shirt makes me a beautiful breast?</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140952">
    <i:boundingBox>9 205 145 55</i:boundingBox>
    <a:body>Do you want my opinion? There's a love affair going on here… Anyway. Talking non sense. We all know Heather is committed to Flickr. She even only dresses at FlickrApparel. Did they say &amp;quot;No Logo&amp;quot;. Doh Dude.</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>

   </flickr:note>

   <flickr:photoset rdf:about="http://www.flickr.com/photos/35034348999@N01/sets/1082058">
    <dc:description></dc:description>
    <dc:title>Flickr</dc:title>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
   </flickr:photoset>

   <flickr:user rdf:about="http://www.flickr.com/people/34427469121@N01">
    <foaf:mbox_sha1sum>00d5b413e52b4d7d35dc982102c49e930a0ef631</foaf:mbox_sha1sum>
    <foaf:name>George Oates</foaf:name>
    <foaf:nick>George</foaf:nick>
   </flickr:user>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140946">
    <i:boundingBox>355 31 103 95</i:boundingBox>
    <a:body>(Yes… I love you heather, you are my dream star)</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <rdf:Description rdf:about="x-urn:flickr:tag">
    <rdfs:subClassOf rdf:resource="http://www.w3.org/2004/02/skos/core#Concept"/>
   </rdf:Description>

   <flickr:tag rdf:about="http://www.flickr.com/tags/usa">
    <skos:prefLabel>usa</skos:prefLabel>
   </flickr:tag>

   <flickr:tag rdf:about="http://www.flickr.com/tags/california">
    <skos:prefLabel>california</skos:prefLabel>
   </flickr:tag>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/geotagged">
    <skos:prefLabel>geotagged</skos:prefLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/geotagged"/>
   </flickr:tag>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/sanfrancisco">
    <skos:prefLabel>san francisco</skos:prefLabel>
    <skos:altLabel>sanfrancisco</skos:altLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/sanfrancisco"/>
   </flickr:tag>

   <flickr:user rdf:about="http://www.flickr.com/people/32373682187@N01">
    <foaf:mbox_sha1sum>479d12dec2090705278d8b2af2c50ac2c46b94d4</foaf:mbox_sha1sum>
    <foaf:name>heather powazek champ</foaf:name>
    <foaf:nick>heather</foaf:nick>
   </flickr:user>

   <flickr:tag rdf:about="http://www.flickr.com/tags/geotagged">
    <skos:prefLabel>geotagged</skos:prefLabel>
   </flickr:tag>

   <dcterms:StillImage rdf:about="http://static.flickr.com/23/30763528_a981fab285.jpg">
    <dcterms:relation>Medium</dcterms:relation>
    <exifi:height>375</exifi:height>
    <exifi:width>500</exifi:width>
    <dcterms:isVersionOf rdf:resource="http://static.flickr.com/23/30763528_a981fab285_o.jpg"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#exif"/>
   </dcterms:StillImage>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/geolat377742">
    <skos:altLabel>geolat377742</skos:altLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <skos:prefLabel rdf:resource="geo:lat=37.7742"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/geolat377742"/>
   </flickr:tag>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142648">
    <i:boundingBox>202 224 50 50</i:boundingBox>
    <a:body>dude! who did this?</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/32373682187@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/cameraphone">
    <skos:prefLabel>cameraphone</skos:prefLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/cameraphone"/>
   </flickr:tag>

   <flickr:user rdf:about="http://www.flickr.com/people/35034348999@N01">
    <foaf:mbox_sha1sum>a4d1b5e38db5e2ed4f847f9f09fd51cf59bc0d3f</foaf:mbox_sha1sum>
    <foaf:name>Aaron Straup Cope</foaf:name>
    <foaf:nick>straup</foaf:nick>
   </flickr:user>

   <rdf:Description rdf:about="x-urn:flickr:comment">
    <rdfs:subClassOf rdf:resource="http://www.w3.org/2000/10/annotation-nsAnnotation"/>
   </rdf:Description>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140942">
    <i:boundingBox>468 141 22 26</i:boundingBox>
    <a:body>*sigh*</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/usa">
    <skos:prefLabel>usa</skos:prefLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/usa"/>
   </flickr:tag>

   <flickr:tag rdf:about="http://www.flickr.com/tags/cameraphone">
    <skos:prefLabel>cameraphone</skos:prefLabel>
   </flickr:tag>

   <rdf:Description rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#exif">
    <exif:flash>32</exif:flash>
    <exif:digitalZoomRatio>100/100</exif:digitalZoomRatio>
    <exif:isoSpeedRatings>1250</exif:isoSpeedRatings>
    <exif:pixelXDimension>1280</exif:pixelXDimension>
    <exif:apertureValue>336/100</exif:apertureValue>
    <exif:pixelYDimension>960</exif:pixelYDimension>
    <exif:focalLength>4.5 mm</exif:focalLength>
    <exif:dateTimeDigitized>2005-08-02T18:12:19PDT</exif:dateTimeDigitized>
    <exif:colorSpace>sRGB</exif:colorSpace>
    <exif:fNumber>f/3.2</exif:fNumber>
    <exif:dateTimeOriginal>2005-08-02T18:12:19PDT</exif:dateTimeOriginal>
    <exif:shutterSpeedValue>4321/1000</exif:shutterSpeedValue>
    <exif:exposureTime>0.05 sec (263/5260)</exif:exposureTime>
    <exif:gainControl>High gain up</exif:gainControl>
   </rdf:Description>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1142656">
    <i:boundingBox>357 193 81 28</i:boundingBox>
    <a:body>eww!</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/32373682187@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <flickr:tag rdf:about="http://www.flickr.com/tags/sanfrancisco">
    <skos:prefLabel>sanfrancisco</skos:prefLabel>
   </flickr:tag>

   <flickr:comment rdf:about="http://www.flickr.com/photos/straup/30763528/#comment8399772">
    <dc:identifier>6065-30763528-8399772</dc:identifier>
    <dc:created>2005-08-02T18:44:52</dc:created>
    <a:body>&amp;quot;you have been note-spammed by a passing mad cow...&amp;quot;
:)</a:body>
    <dc:creator rdf:resource="http://www.flickr.com/people/32373689382@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:comment>

   <dcterms:StillImage rdf:about="http://static.flickr.com/23/30763528_a981fab285_m.jpg">
    <dcterms:relation>Small</dcterms:relation>
    <exifi:height>180</exifi:height>
    <exifi:width>240</exifi:width>
    <dcterms:isVersionOf rdf:resource="http://static.flickr.com/23/30763528_a981fab285_o.jpg"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#exif"/>
   </dcterms:StillImage>

   <flickr:tag rdf:about="http://www.flickr.com/tags/geolong122417068">
    <skos:prefLabel>geolong122417068</skos:prefLabel>
   </flickr:tag>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1143239">
    <i:boundingBox>184 164 50 50</i:boundingBox>
    <a:body>Baaaaarp!</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/34427469121@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <dcterms:StillImage rdf:about="http://static.flickr.com/23/30763528_a981fab285_t.jpg">
    <dcterms:relation>Thumbnail</dcterms:relation>
    <exifi:height>75</exifi:height>
    <exifi:width>100</exifi:width>
    <dcterms:isVersionOf rdf:resource="http://static.flickr.com/23/30763528_a981fab285_o.jpg"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#exif"/>
   </dcterms:StillImage>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1140945">
    <i:boundingBox>433 103 50 50</i:boundingBox>
    <a:body>(fuck… fuck…)</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/44124415257@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>

   <rdf:Description rdf:about="x-urn:flickr:user">
    <rdfs:subClassOf rdf:resource="http://xmlns.com/foaf/0.1/Person"/>
   </rdf:Description>

   <flickr:grouppool rdf:about="http://www.flickr.com/groups/97155967@N00/pool">
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/groups/97155967@N00"/>
   </flickr:grouppool>

   <flickr:user rdf:about="http://www.flickr.com/people/32373689382@N01">
    <foaf:mbox_sha1sum>e0d207bb5643d4d7dd60e72d4ce2a94bae0e13b6</foaf:mbox_sha1sum>
    <foaf:name>Boris Anthony</foaf:name>
    <foaf:nick>bopuc</foaf:nick>
   </flickr:user>

   <flickr:tag rdf:about="http://www.flickr.com/photos/35034348999@N01/tags/geolong122417068">
    <skos:altLabel>geolong122417068</skos:altLabel>
    <dc:creator rdf:resource="http://www.flickr.com/people/35034348999@N01"/>
    <skos:prefLabel rdf:resource="geo:long=-122.417068"/>
    <dcterms:isPartOf rdf:resource="http://www.flickr.com/tags/geolong122417068"/>
   </flickr:tag>

   <flickr:group rdf:about="http://www.flickr.com/groups/97155967@N00">
    <dc:description></dc:description>
    <dc:title>aaronland</dc:title>
   </flickr:group>

   <flickr:tag rdf:about="http://www.flickr.com/tags/geolat377742">
    <skos:prefLabel>geolat377742</skos:prefLabel>
   </flickr:tag>

   <cc:License rdf:about="http://creativecommons.org/licenses/by-nd/2.0/">
    <cc:requires rdf:resource="http://web.resource.org/cc/Notice"/>
    <cc:requires rdf:resource="http://web.resource.org/cc/Attribution"/>
    <cc:requires rdf:resource="http://web.resource.org/cc/ShareAlike"/>
    <cc:permits rdf:resource="http://web.resource.org/cc/Reproduction"/>
    <cc:permits rdf:resource="http://web.resource.org/cc/Distribution"/>
   </cc:License>

   <dcterms:StillImage rdf:about="http://static.flickr.com/23/30763528_a981fab285_o.jpg">
    <dcterms:relation>Original</dcterms:relation>
    <exifi:height>960</exifi:height>
    <exifi:width>1280</exifi:width>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
    <rdfs:seeAlso rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528#exif"/>
   </dcterms:StillImage>

   <rdf:Description rdf:about="x-urn:flickr:note">
    <rdfs:subClassOf rdf:resource="http://www.w3.org/2000/10/annotation-nsAnnotation"/>
   </rdf:Description>

   <flickr:note rdf:about="http://www.flickr.com/photos/35034348999@N01/30763528#note-1148950">
    <i:boundingBox>342 197 28 33</i:boundingBox>
    <a:body>Is that just one big boob, or...?</a:body>
    <i:regionDepicts rdf:resource="http://static.flickr.com/23/30763528_a981fab285.jpg"/>
    <a:author rdf:resource="http://www.flickr.com/people/34427469121@N01"/>
    <a:annotates rdf:resource="http://www.flickr.com/photos/35034348999@N01/30763528"/>
   </flickr:note>
  </rdf:RDF>

=head1 VERSION

2.92

=head1 DATE

$Date: 2006/09/01 15:56:17 $

=head1 AUTHOR

Aaron Straup Cope E<lt>ascope@cpan.orgE<gt>

=head1 SEE ALSO 

L<Net::Flickr::API>

L<Net::Flickr::RDF>

L<Config::Simple>

http://www.flickr.com/services/api/misc.userauth.html

=head1 BUGS

Please report all bugs via http://rt.cpan.org

=head1 LICENSE

Copyright (c) 2005-2006 Aaron Straup Cope. All Rights Reserved.

This is free software. You may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

return 1;
