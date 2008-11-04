package CatalystX::CMS::File;
use strict;
use warnings;
use base qw(
    SVN::Class::File
    Path::Class::File::Lockable
);
use Class::C3;
use Carp;
use Data::Dump qw( dump );

our $VERSION = '0.001';

__PACKAGE__->mk_accessors(qw( attrs content ext ));

=head1 NAME

CatalystX::CMS::File - class representing a template file

=head1 SYNOPSIS

 use CatalystX::CMS::File;

 # longhand
 my $file = CatalystX::CMS::File->new( $path_to_file );
 $file->fetch if $page->size;
 $file->content('hello world');
 $file->title('super foo');
 $file->write;
 $file->commit or die $file->errstr;
 
 # shorthand
 my $file = CatalystX::CMS::File->new(
                        path    => $path_to_file,
                        title   => 'super foo',
                        content => 'hello world',
                        );
 eval { $file->save  } or die $file->errstr;
 print "$file was saved\n";
                        
=head1 DESCRIPTION

CatalystX::CMS::File is the object model for the Template Toolkit files that
make up the content system of your application. 
Each object represents a C<.tt>
file on the filesystem in a Subversion working directory.
An object can be read, written, locked and unlocked on the filesystem.
As a subclass of SVN::Class::File, the object can be interrogated 
for its history, added, deleted, committed or updated.

=head2 new( I<path> )

=head2 new( path => I<path> [, %param ] )

Create a new object.

Either form of new() may be used, but I<path> is always
required.

=cut

sub new {
    my $class = shift;
    my @param = @_;
    my ( $self, %arg );

    if ( !@param ) {
        croak "path required";
    }
    elsif ( @param == 1 ) {
        $self = $class->next::method(@param);
    }
    elsif ( @param % 2 ) {
        croak "new() requires either a path or a hash of key/value pairs";
    }
    elsif ( @param == 2 && $param[0] ne 'path' ) {
        $self = $class->next::method(@param);
    }
    else {
        %arg = @param;
        my $path = delete $arg{path} or croak "path required";
        $self = $class->next::method($path);
    }

    # add other attributes
    $self->{$_} = $arg{$_} for keys %arg;

    $self->{attrs} ||= {};

    # path cleanup
    $self->{ext} ||= '.tt';

    # re-create the object with extension
    my $ext = $self->{ext};
    unless ( $self =~ m/$ext$/ ) {
        $self = $self->new( $self . $self->{ext} );
    }

    #carp dump $self;

    return $self;
}

=head2 read

Reads the file from disk and parses the metadata attributes and content,
thereafter accessible via the attrs() and content() methods.

Will croak if path() is false, empty or non-existent.

=cut

sub read {
    my $self = shift;
    croak("invalid path: $self") unless ( -f $self && -s $self );

    # TODO does ->slurp correctly handle utf8?
    $self->_parse_page( scalar $self->slurp );
    return $self;
}

sub _parse_page {
    my ( $self, $buf ) = @_;

    # example:
    #
    #  [% # CMS
    #       cmspage.attrs.title = 'foo'
    #  %]
    #
    #   this is a page.
    #

    my ( $attrs, $content )
        = ( $buf =~ m/^\s*\[\%\s+\#\s*CMS\s+(.+?)\%\]\s*(.*)$/s );
    if ( $attrs && $content ) {
        while ( $attrs =~ m/\bcmspage\.attrs\.(\w+)\s*=\s*(['"])(.+?)\2/sg ) {
            my $key = $1;
            my $val = $3;

            # reserved words
            next if $key eq 'attrs';
            next if $key eq 'content';
            next if $key eq 'page';

            $self->{attrs}->{$key} = $val;
        }

        $self->content($content);
    }
    else {
        $self->content($buf);
    }
    return $self;
}

=head2 write( [I<ignore_lock>] )

Writes attrs() and content() to file location in TT-compatible format.

Will croak on any error.

If the I<ignore_lock> flag is true, write() will ignore any true
value of locked(). Otherwise, will croak() if locked() is true.

Returns the size of the resulting file.

=cut

sub write {
    my $self = shift;
    my $force = shift || 0;

    if ( $self->locked && !$force ) {
        croak "write failed. $self is locked";
    }

    my $fh = $self->openw();

    # make sure we have at least one newline at end of file.
    my $content = $self->content || '';
    chomp $content;
    $content .= "\n";

    print {$fh} join( "\n", $self->_ttify_attrs, $content )
        or croak "write failed for $self: $!";
    $fh->close;

    return -s $self;
}

=head2 create( I<user> )

Acquires lock for I<user> and writes files as a new page.

=cut

sub create {
    my $self = shift;
    my $user = shift or croak "user required";

    # create any required parent directories
    $self->dir->mkpath();

    if ( $self->locked or -s $self ) {
        croak "cannot create $self : locked or already exists";
    }

    $self->lock($user);
    $self->attrs->{owner} = $user;
    $self->content('[ this is a new page ]');
    return $self->write(1);
}

=head2 update

Calls write().

B<NOTE:> This is not the same as the SVN::Class->update method!
If you want that method, use the up() alias instead.

=cut

sub update {
    my $self = shift;
    if ( !-s $self ) {
        croak "cannot update an empty file";
    }
    $self->write(@_);
}

sub _ttify_attrs {
    my $self = shift;

    # make a TT-hash out of a Perl hash
    my $attrs = $self->attrs;
    my $buf   = "[% # CMS\n\n";
    for my $key ( sort keys %$attrs ) {
        $buf .= "    cmspage.attrs.$key = '" . qq($attrs->{$key}) . "';\n";
    }
    return $buf . "\n%]";
}

=head2 save( I<message> [, I<leave_lock>] )

Will write() file, add() to the SVN workspace if necessary,
and then call commit( I<message> ).

Returns -1 if status() of file indicates no modification.
Otherwise, returns commit() return value.

Pass a true for I<leave_lock> to leave the lock file intact
after the commit().

=cut

sub save {
    my $self       = shift;
    my $message    = shift || '[no log message]';
    my $leave_lock = shift || 0;

    # pass force flag to write() since we want lock
    # to persist till we've committed.

    $self->write(1) or croak "$self failed to write(): $!";

    # might be that the parent dir hasn't been added yet
    # so will get err rather than status.
    # track what level we need to commit at.
    my @to_add;

    my $dir = $self->dir;
    $dir->debug( $self->debug );

    my $self_status = $self->status;
    my $dir_status  = $dir->status;

    if ( $self->debug ) {
        warn "self = $self  status = $self_status";
        warn "dir = $dir  status = $dir_status";
    }

    # walk up the tree
    while ( $dir_status eq '0' && $dir->error ) {

        $self->debug and warn "no status for $dir";
        unshift( @to_add, $dir );
        $dir        = $dir->parent;
        $dir_status = $dir->status;
        $self->debug and warn "dir $dir status = $dir_status";

        # avoid infinite loops
        if ( $dir eq '/' ) {
            croak "infinite loop looking up svn workdir tree for $self";
        }
    }

    # found one that svn knows about
    if ( $dir_status eq '?' or $dir_status eq 'A' ) {
        unshift( @to_add, $dir );
    }

    $self->debug and warn "to_add: " . dump \@to_add;

    # we 'add' each dir non-recursively
    # so that we do not add unaffected files (like lock files) by mistake.
    for my $d (@to_add) {
        $d->add( ['-N'] ) unless $d->status eq 'A';
        $d->commit( "new directory", ['-N'] )
            or croak "add directory $d failed: " . $d->errstr;
    }

    # now check the stat of the file itself
    my $stat = $self->status;
    if ( $stat && $stat eq '?' ) {
        $self->add;
    }

    my $ret;

    # is file modified at all?
    if ( $self->modified ) {
        $ret = $self->commit($message);
    }
    else {

        # no attempt made to commit unmodified file
        $ret = -1;
    }

    unless ($leave_lock) {
        $self->unlock or croak "can't unlock $self: $!";
    }
    return $ret;
}

=head2 escape_tt

Returns content() with all TT code wrapped in special XHTML tagset

 <code class="tt">

This is to allow for such code to be escaped online or otherwise parsed
with a XML parser.

=cut

sub escape_tt {
    my $self    = shift;
    my $content = $self->content;

    $content =~ s/\[\%/<code class="tt">\[\%/g;
    $content =~ s/\%\]/\%\]<\/code>/g;

    return $content;
}

# this isn't currently used but could be.
#sub as_chunks {
#    my $self = shift;
#    my $escape = shift || 0;
#
#    # NOTE the regex keeps the surrounding whitespace WITH the PROCESS
#    # line so that it is preserved in the web interaction.
#    my @chunks = split( m!(\s*\[\%\ +PROCESS tt/share/\S+\ +\%\]\s*)!s,
#        $self->content );
#
#    # turn into array of hashrefs
#    my @hashes;
#
#    #carp "raw chunks: " . dump \@chunks;
#
#    for my $chunk (@chunks) {
#        my $h = { content => $chunk };
#
#        # editable text
#        unless ( $chunk =~ m/^\s*\[\%\s+PROCESS/ ) {
#            $h->{editable} = 1;
#
#            # wrap TT instructions in <pre> tags so they show verbatim
#            if ($escape) {
#                $h->{content} =~ s,\[\%,<pre class="tt">\[\%,g;
#                $h->{content} =~ s,\%\],\%\]</pre>,g;
#            }
#
#        }
#
#        # shared text -- render it as TT would but just that chunk.
#        else {
#            $h->{editable} = 0;
#        }
#
#        push( @hashes, $h );
#    }
#
#    return \@hashes;
#}
#
#=head2 save_chunk( I<chunk_id>, I<new_text>, I<message> )
#
#I<chunk_id> is element of the array returned by as_chunks().
#
#I<new_text> is the text to be saved at that element.
#
#Calls save() with I<message>. Returns save() return value.
#
#=cut
#
#sub save_chunk {
#    my $self    = shift;
#    my $id      = shift || 0;
#    my $text    = shift || '';
#    my $message = shift or croak "need save message";
#
#    my $chunks = $self->as_chunks;    # NO escape
#
#    $chunks->[$id]->{content} = $text;
#
#    carp dump $chunks;
#
#    $self->content( join( '', map { $_->{content} } @$chunks ) );
#
#    return $self->save( $message, 1 );
#}

1;

__END__

=head1 AUTHOR

Peter Karman, C<< <karman@cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-catalystx-cms@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.  I will be notified, and then you'll automatically be
notified of progress on your bug as I make changes.

=head1 ACKNOWLEDGEMENTS

The Minnesota Supercomputing Institute C<< http://www.msi.umn.edu/ >>
sponsored the development of this software.

=head1 COPYRIGHT & LICENSE

Copyright 2008 by the Regents of the University of Minnesota.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

