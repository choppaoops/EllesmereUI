#!/usr/bin/perl
# Builds the ring textures EllesmereUICdmBuffRings.lua sets as Cooldown swipe
# textures (Tracking Bar groups displayed as rings).
#
# media/basics/rings/ring_NN.png for NN = 01..COUNT: a white annulus, the shape
# in alpha, SIZE x SIZE. The outer edge sits PAD texels inside the texture edge;
# ring width / texture width = K0 * KF^(NN-1). A mask does not clip a Cooldown's
# swipe, so the ring shape has to live in the texture, and a fixed set of
# widths stands in for any width: each ring picks the texture whose ratio is
# closest to its own width / diameter.
#
# Texels the edges cross are supersampled SUB x SUB; the rest are fully in or
# fully out. SIZE, PAD, K0, KF and COUNT must match RING_SIZE, RING_PAD,
# RING_K0, RING_KF and RING_COUNT in the Lua file.
#
# Needs only core Perl (Compress::Zlib). Run from the suite root:
#   perl .tools/buff-rings/make_ring_art.pl
use strict;
use warnings;
use Compress::Zlib;
use File::Basename qw(dirname);
use File::Spec;

my ($SIZE, $PAD, $K0, $KF, $COUNT, $SUB) = (512, 1, 0.004, 1.1, 51, 8);

my $ROOT = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..', '..'));
my $OUT = File::Spec->catdir($ROOT, 'media', 'basics', 'rings');

sub chunk {
    my ($type, $data) = @_;
    return pack('N', length $data) . $type . $data . pack('N', crc32($type . $data));
}

# Alpha (0..255) of texel (x, y) for the annulus ri <= r <= ro round (c, c).
# A texel whose nearest and farthest points both lie on one side of each edge
# is solid; only texels an edge crosses are sampled.
sub alpha {
    my ($x, $y, $c, $ri, $ro) = @_;
    my ($dx, $dy) = ($x + 0.5 - $c, $y + 0.5 - $c);
    my $d = sqrt($dx * $dx + $dy * $dy);
    my $h = 0.7072;    # half the texel diagonal
    return 0 if $d - $h >= $ro || $d + $h <= $ri;
    return 255 if $d - $h >= $ri && $d + $h <= $ro;
    my ($ro2, $ri2, $hit) = ($ro * $ro, $ri * $ri, 0);
    for my $sy (0 .. $SUB - 1) {
        my $py = $y + ($sy + 0.5) / $SUB - $c;
        for my $sx (0 .. $SUB - 1) {
            my $px = $x + ($sx + 0.5) / $SUB - $c;
            my $d2 = $px * $px + $py * $py;
            $hit++ if $d2 <= $ro2 && $d2 >= $ri2;
        }
    }
    return int($hit / ($SUB * $SUB) * 255 + 0.5);
}

sub write_ring {
    my ($path, $k) = @_;
    my $c = $SIZE / 2;
    my $ro = $c - $PAD;
    my $ri = $ro - $k * $SIZE;
    my $raw = '';
    for my $y (0 .. $SIZE - 1) {
        $raw .= "\0";
        for my $x (0 .. $SIZE - 1) {
            $raw .= pack('C4', 255, 255, 255, alpha($x, $y, $c, $ri, $ro));
        }
    }
    my $png = "\x89PNG\r\n\x1a\n"
        . chunk('IHDR', pack('NNCCCCC', $SIZE, $SIZE, 8, 6, 0, 0, 0))
        . chunk('IDAT', compress($raw, 9))
        . chunk('IEND', '');
    open my $fh, '>:raw', $path or die "$path: $!\n";
    print $fh $png;
    close $fh;
    return length $png;
}

die "ring $COUNT leaves no hole\n" if $K0 * $KF ** ($COUNT - 1) * $SIZE >= $SIZE / 2 - $PAD;
mkdir $OUT unless -d $OUT;
my $total = 0;
for my $n (1 .. $COUNT) {
    my $k = $K0 * $KF ** ($n - 1);
    my $bytes = write_ring(File::Spec->catfile($OUT, sprintf('ring_%02d.png', $n)), $k);
    $total += $bytes;
    printf "ring_%02d  k %.4f  width %6.2f texels  %6d bytes\n", $n, $k, $k * $SIZE, $bytes;
}
printf "%d textures, %d bytes\n", $COUNT, $total;
