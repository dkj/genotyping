use utf8;

package Build;

use strict;
use warnings;
use Carp;
use File::Basename;
use File::Copy;
use File::Path qw(make_path);
use File::Spec;

use base 'Module::Build';

#
# Prepare configuration for tests
#
sub ACTION_test {
  my $self = shift;

  $self->copy_files_by_category('conf_files', './blib');
  $self->copy_files_by_category('ini_files', './blib');

  $self->SUPER::ACTION_test;
}

#
# Add targets to the build file.
#
sub ACTION_install_config {
  my ($self) = @_;

  $self->process_conf_files;
  $self->process_ini_files;

  return $self;
}

sub ACTION_install_gendermix {
    my $self = shift;
    my $gendermix_manifest = './etc/gendermix_manifest.txt';
    $self->process_alternate_manifest($gendermix_manifest);
    return $self;
}

sub ACTION_install_R {
  my ($self) = @_;
  $self->process_R_files;
  return $self;
}

sub process_conf_files {
  my ($self) = @_;
  return $self->copy_files_by_category('conf_files', $self->install_base, 1);
}

sub process_ini_files {
  my ($self) = @_;
  return $self->copy_files_by_category('ini_files', $self->install_base, 1);
}

sub process_R_files {
  my ($self) = @_;
  return $self->copy_files_by_category('R_files', $self->install_base, 1);
}

sub process_alternate_manifest {
    # reads an alternate manifest
    # manifest lists one file per line, followed by (optional) translation
    # installs each item in manifest, under the install_base directory
    # use to install standalone gendermix check
    my ($self, $manifest_path) = @_;
    open my $in, "<", $manifest_path ||
        croak "Cannot open manifest $manifest_path: $!";
    my %manifest;
    while (<$in>) {
        chomp;
        my @words = split;
        my $src = shift @words;
        my $dest = shift @words;
        if ($dest) { $manifest{$src} = $dest; }
        else { $manifest{$src} = $src; }
    }
    close $in || croak "Cannot close manifest $manifest_path: $!";
    my $dest_base = $self->install_base;
    my @installed;
    foreach my $src_file (keys %manifest) {
        my $dest_file = File::Spec->catfile($dest_base,
                                            $manifest{$src_file});
        my $file = $self->copy_if_modified(from => $src_file, to => $dest_file);
        if ($file) {
            push(@installed, $file);
            print STDERR "Installing $file\n";
        }
    }
    return @installed;
}

sub copy_files_by_category {
  my ($self, $category, $destination, $verbose) = @_;

  # This is horrible - there must be a better way
  if ($self->current_action eq 'install_config' ||
      $self->current_action eq 'install_R' ||
      $self->current_action eq 'test') {
    my $translations = $self->{properties}->{$category};

    my @installed;
    foreach my $src_file (keys %$translations) {
      my $dest_file = File::Spec->catfile($destination,
                                          $translations->{$src_file});

      my $file = $self->copy_if_modified(from => $src_file, to => $dest_file);
      if ($file) {
        push(@installed, $file);
        print STDERR "Installing $file\n" if $verbose;
      }
    }

    return @installed;
  }
}


1;
