use strict;
use warnings;

use Fatal qw(open close);
use FindBin qw($Bin);
use Imager;
use Isucon3Final::Web;

use Test::More;

my $data = "$Bin/data";
my $image_diff = "$Bin/image_diff";

package U {
    use File::Temp qw/ tempfile /;
    use POSIX qw/ floor /;
    use File::Copy;

    sub convert {
        my $self = shift;
        my ($orig, $ext, $w, $h) = @_;
        my ($fh, $filename) = tempfile();
        my $newfile = "$filename.$ext";
        system("convert", "-geometry", "${w}x${h}", $orig, $newfile);
        open my $newfh, "<", $newfile or die $!;
        read $newfh, my $data, -s $newfile;
        close $newfh;
        unlink $newfile;
        unlink $filename;
        $data;
    }

    sub crop_square {
        my $self = shift;
        my ($orig, $ext) = @_;
        my $identity = `identify $orig`;
        my (undef, undef, $size) = split / +/, $identity;
        my ($w, $h) = split /x/, $size;
        my ($crop_x, $crop_y, $pixels);
        if ( $w > $h ) {
            $pixels = $h;
            $crop_x = floor(($w - $pixels) / 2);
            $crop_y = 0;
        }
        elsif ( $w < $h ) {
            $pixels = $w;
            $crop_x = 0;
            $crop_y = floor(($h - $pixels) / 2);
        }
        else {
            $pixels = $w;
            $crop_x = 0;
            $crop_y = 0;
        }
        my ($fh, $filename) = tempfile();
        system("convert", "-crop", "${pixels}x${pixels}+${crop_x}+${crop_y}", $orig, "$filename.$ext");
        unlink $filename;
        return "$filename.$ext";
    }
}

sub save_to_tempfile {
    my($binary) = @_;

    my $filename = File::Temp::tempnam($data, 'XXX');
    open my $fh, ">:raw", $filename;
    print $fh $binary;
    close $fh;
    return $filename;
}

subtest 'convert', sub {
    my $g = Isucon3Final::Web->convert("$data/fujiwara.jpg", "jpg", 73, 90);
    my $x = U->convert("$data/fujiwara.jpg", "jpg", 73, 90);

    my $got = save_to_tempfile($g);
    my $expected = save_to_tempfile($x);
    is system("$image_diff $got $expected"), 0;

    unlink $got;
    unlink $expected;
};

subtest 'image_crop', sub {
    my $got = Isucon3Final::Web->crop_square("$data/fujiwara.jpg", "jpg");
    my $expected = U->crop_square("$data/fujiwara.jpg", "jpg");
    is system("$image_diff $got $expected"), 0;

    unlink $got;
    unlink $expected;
};

done_testing;
