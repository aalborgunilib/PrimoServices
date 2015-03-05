package PrimoServices::Utility;
use strict;
use warnings;
use Dancer ':syntax';

# Export our functions
use Exporter 'import';
our @ISA = qw(Exporter);
our @EXPORT_OK = qw( get_as_scalar get_as_array put_years_in_order );
our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );

#
# Subs
#

sub get_as_scalar {
	my $key = shift;

	if ( ref $key eq 'ARRAY' ) {
		return $key->[0];
	}
	else {
		return $key;
	}
}

sub get_as_array {
	my $key = shift;

	if ( ref $key eq 'ARRAY') {
		return $key;
	}
	else {
		return [ $key ];
	}
}

# make a pretty printed year range
# (dates pased to the sub needs to be sorted and unique)
sub put_years_in_order {
	my @range = @_;

	# just return "unknown" no year exist
	return "????" unless $range[0];

	# is this a current year only?
	return $range[0] if ( ! defined $range[1] );

	my $in_order = '';

	# loop through each year in the array
	for ( my $index=0 ; $index<@range ; $index++ ) {
		# this is the last year in the range
		if ( ! defined $range[$index+1] ) {
			# is this then the end of a range
			$in_order .= $range[$index];
			last;
		}
		# this is a single year (current year +1 not equal to next year AND current year -1 not equal to previous year)
		if ( ($range[$index]+1 != $range[$index+1]) && ($range[$index]-1 != $range[$index-1]) ) {
			$in_order .= $range[$index] . ", ";
			next;
		}
		# this is the beginning of a year range (current year not equal to previous year +1)
		if ( $range[$index] ne $range[$index-1]+1 ) {
			$in_order .= $range[$index] . '-';
			next;
		}
		# this is the ending of a year range (current year +1 not equal next year)
		if ( $range[$index]+1 != $range[$index+1] ) {
			$in_order .= $range[$index] . ", ";
			next;
		}
	}

	return $in_order;
}

true;