package MyCMS;

use strict;
use warnings;
use lib qw( ../../lib ../lib lib  );

use Catalyst::Runtime '5.70';
use Catalyst qw/-Debug ConfigLoader Static::Simple/;

our $VERSION = '0.01';

use IPC::Cmd;
use File::Spec;

# setup test env **outside** our app dir,
# so we can use svn without conflict.
# we don't use File::Temp because we want a consistent path.
my $tmpdir  = File::Spec->tmpdir();
my $repos   = Path::Class::dir( $tmpdir, 'cxcms', 'repos' );
my $cmsroot = Path::Class::dir( $tmpdir, 'cxcms', 'work' );

# check if setup already exists
unless ( -d $repos && -s "$repos/format" ) {
    $repos->mkpath;
    $cmsroot->mkpath;
    IPC::Cmd::run( command => "svnadmin create $repos" );
    IPC::Cmd::run( command => "svn mkdir file://$repos/cmstest -m init" );
    IPC::Cmd::run(
        command => "cd $cmsroot && svn co file://$repos/cmstest . " );
}

END {
    unless ( $ENV{PERL_DEBUG} ) {
        $repos->rmtree;
        $cmsroot->rmtree;
    }
}

# get our base static files for free
# TODO this should only be necessary during devel
# and/or until we install a local copy of the base .js and .css
use Class::Inspector;
use Path::Class::Dir;
use CatalystX::CMS;
my $template_base = Class::Inspector->loaded_filename('CatalystX::CMS');
$template_base =~ s/\.pm$//;

__PACKAGE__->config(
    name   => 'MyCMS',
    static => {
        include_path => [
            __PACKAGE__->path_to('root'),
            Path::Class::Dir->new( $template_base, 'tt' ),
        ],
    },
    cms => {
        use_editor => 1,
        use_layout => 1,
        root => { r => [ __PACKAGE__->path_to('root') ], rw => [$cmsroot] },

        #default_type    => 'html',
        #default_flavour => 'default',
    },
);
__PACKAGE__->setup;

1;
