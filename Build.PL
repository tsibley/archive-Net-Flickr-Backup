# $Id: Build.PL,v 1.10 2005/09/25 22:45:31 asc Exp $

use strict;
use Module::Build;

my $build = Module::Build->new(module_name => 'Net::Flickr::Backup',
			       # dist_author
			       # dist_abstract
			       dist_version_from => 'lib/Net/Flickr/Backup.pm',
			       license           => 'perl',
			       requires => {
				   'perl'            => '>= 5.8.0',
				   'Net::Flickr::RDF' => '>= 1.0',
				   'Encode'          => '>= 2.09',
				   'File::Find::Rule' => '0',
				   'Date::Parse'     => '>= 2.27',
				   'Date::Format'    => '>= 2.22',
				   'LWP::Simple'     => '>= 1.38',
				   'IO::AtomicFile'  => '>= 2.101',
				   'Memoize'         => '0',
				   'Sys::Hostname::FQDN' => '0',
			       },
			       build_requires => {
				   'Test::Simple'              => '>= 0.47',
			       },
			       create_readme      => 1,
			       create_makefile_pl => 'passthrough');

$build->create_build_script();
