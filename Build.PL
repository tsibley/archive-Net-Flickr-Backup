# $Id: Build.PL,v 1.9 2005/09/01 16:44:59 asc Exp $

use strict;
use Module::Build;

my $build = Module::Build->new(module_name => 'Net::Flickr::Backup',
			       # dist_author
			       # dist_abstract
			       dist_version_from => 'lib/Net/Flickr/Backup.pm',
			       license           => 'perl',
			       requires => {
				   'perl'            => '>= 5.8.0',
				   'Encode'          => '>= 2.09',
				   'File::Find::Rule' => '0',
				   'Config::Simple'  => '0',
				   'Text::Unidecode' => '>= 0.04',
				   'RDF::Simple'     => '>= 0.21',
				   'Date::Parse'     => '>= 2.27',
				   'Date::Format'    => '>= 2.22',
				   'LWP::Simple'     => '>= 1.38',
				   'IO::AtomicFile'  => '>= 2.101',
				   'Flickr::API'     => '>= 0.07',
				   # Tries to use XML::LibXML first
				   'XML::XPath'      => '>= 1.13',
				   'Log::Dispatch'   => '>= 2.10',
			       },
			       build_requires => {
				   'Test::Simple'              => '>= 0.47',
			       },
			       create_readme      => 1,
			       create_makefile_pl => 'passthrough');

$build->create_build_script();
