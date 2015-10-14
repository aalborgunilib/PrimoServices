package PrimoServices::Parsers;
use strict;
use warnings;
use Dancer ':syntax';
use Dancer::Exception ':all';

use PrimoServices::Utility ':all';

use JSON::XS();
use List::MoreUtils();

# Export our functions
use Exporter 'import';
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
	parse_record
	parse_frbg
	parse_primocentral
	parse_keyword
	parse_googlebooks
	parse_journaltocs
	parse_rsi );
our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );

#
# Subs
#

sub parse_record {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my $json;
	my %values;

	# JSON::XS will croak on error
	try{
		$json = JSON::XS->new->utf8->decode($$content_ref);
		
		$values{id} = $id;
		$values{primoStatus} = 'OK';

		$values{metadata}{isbn} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{isbn});
		$values{metadata}{'@isbn'} = get_as_array($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{isbn});
		$values{metadata}{issn} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{issn});
		$values{metadata}{'@issn'} = get_as_array($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{issn});
		
		$values{delcategory} = get_as_array($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{delivery}{delcategory});
		@{$values{delcategory}} = List::MoreUtils::apply { s/(^\$\$V|\$\$O.*$)//g } @{$values{delcategory}} if @{$values{delcategory}}[0];
		@{$values{delcategory}} = List::MoreUtils::uniq @{$values{delcategory}} if @{$values{delcategory}}[1];

		$values{type} = $json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{display}{type};
		$values{availability} = $json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{LIBRARIES};
		$values{metadata}{date} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{date});
		$values{metadata}{volume} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{volume});
		$values{metadata}{issue} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{issue});
		$values{metadata}{issue} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{spage});

		$values{metadata}{atitle} = get_as_scalar($json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}{PrimoNMBib}{record}{addata}{atitle});
	}
	catch {
		# JSON was malformed so we cannot tell the number of hits
		$values{id} = $id;
		$values{primoStatus} = 'Record failed in JSON conversion';
		$values{error} = $_;
	};

	return %values;
}

sub parse_frbg {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my $json;
	my %values;

	# JSON::XS will croak on error
	try{
		$json = JSON::XS->new->utf8->decode($$content_ref);

		$values{id} = $id;
		$values{primoStatus} = 'OK';

		# Iterate through records in frbr group
		my @dates;
		foreach my $doc ( @{$json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{DOC}} ) {
			push @dates, $doc->{PrimoNMBib}{record}{display}{creationdate};
		}

		my @uniqDates = List::MoreUtils::uniq(sort @dates);
		
		$values{years} = join(", ", @uniqDates);

		# Check if the returned years are "pure"
		if ( grep(/^\d{4}$/, @uniqDates) ) {
			$values{yearsRange} = put_years_in_order(@uniqDates);
		}
		# If we are getting e.g. year ranges back from frbr groups
		else {
			$values{yearsRange} = $values{years};
		}

		# Make compact date ranges: 19xx-yy but not past millennia
		$values{yearsRange} =~ s{(?<=18\d\d-)(18)(\d\d)}{$2}g;
		$values{yearsRange} =~ s{(?<=19\d\d-)(19)(\d\d)}{$2}g;
		$values{yearsRange} =~ s{(?<=20\d\d-)(20)(\d\d)}{$2}g;
	}
	catch {
		# JSON was malformed so we cannot tell the number of hits
		$values{id} = $id;
		$values{primoStatus} = 'Record failed in JSON conversion';
		$values{error} = $_;
	};

	return %values;
}

sub parse_keyword {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my $json;
	my %values;

	# JSON::XS will croak on error
	try{
		$json = JSON::XS->new->utf8->decode($$content_ref);
		$values{$data_ref->{request_lookup_table}{$req_id}{keyword}} = $json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{'@TOTALHITS'};
	}
	catch {
		# JSON was malformed so we cannot tell the number of hits
		$values{$data_ref->{request_lookup_table}{$req_id}{keyword}} = '...';
	};

	return %values;
}

sub parse_primocentral {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my $json;
	my %values;

	# JSON::XS will croak on error
	try{
		$json = JSON::XS->new->utf8->decode($$content_ref);
		$values{totalHits} = $json->{SEGMENTS}{JAGROOT}{RESULT}{DOCSET}{'@TOTALHITS'};

		my @facets = @{$json->{SEGMENTS}{JAGROOT}{RESULT}{FACETLIST}{FACET}};

		# Iterate through facets for the "tlevel"-facet
		foreach my $facet ( @facets ) {
			if ( $facet->{'@NAME'} eq "tlevel" ) {
				# If there is more than one "tlevel"-facet
				if ( ref $facet->{FACET_VALUES} eq "ARRAY" ) {
					foreach my $tlevel ( @{$facet->{FACET_VALUES}} ) {
						if ( $tlevel->{'@KEY'} eq "online_resources" ) {
							$values{onlineHits} = $tlevel->{'@VALUE'};
						}
						if ( $tlevel->{'@KEY'} eq "peer_reviewed" ) {
							$values{peerReviewedHits} = $tlevel->{'@VALUE'};
						}
					}
				}
				# If there is only one
				else {
					$values{onlineHits} = $facet->{FACET_VALUES}{'@VALUE'} if $facet->{FACET_VALUES}{'@KEY'} eq "online_resources";
					$values{peerReviewedHits} = $facet->{FACET_VALUES}{'@VALUE'} if $facet->{FACET_VALUES}{'@KEY'} eq "peer_reviewed";					
				}
			}
		}
	};

	return %values;
}

sub parse_googlebooks {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my $json;
	my %values;

	# JSON::XS will croak on error
	try{
		$json = JSON::XS->new->utf8->decode($$content_ref);

		# Only process if there is a 1:1 match
		if ( $json->{totalItems} eq '1' ) {
			$values{id} = $data_ref->{request_lookup_table}{$req_id}{linked_item};
			$values{gbsid} = $json->{items}[0]{id};
			$values{previewLink} = $json->{items}[0]{volumeInfo}{previewLink};
			$values{webReaderLink} = $json->{items}[0]{accessInfo}{webReaderLink};
			$values{viewability} = $json->{items}[0]{accessInfo}{viewability};
		}
	}
	catch {
		# JSON was malformed so we cannot tell the number of hits
	};

	return %values;
}

sub parse_journaltocs {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my %values;

	if ( $$content_ref =~ m{
		<title>JournalTOCs[ ]API[ ]-[ ]Found
		}sxmi ) {
		$values{id} = $data_ref->{request_lookup_table}{$req_id}{linked_item};
		$values{link} = config->{journaltocs}{deeplink} . $data_ref->{request_lookup_table}{$req_id}{issn} . '?embed';
		$values{rssFeed} = config->{journaltocs}{deeplink} . 'rss/' . $data_ref->{request_lookup_table}{$req_id}{issn};
	}

	return %values;
}

sub parse_rsi {
	my $data_ref = shift;
	my $content_ref = shift;
	my $id = shift;
	my $req_id = shift;

	my %values;

	if ( $$content_ref !~ m{
		<RESULT>not[ ]found</RESULT>
		}sxmi
		&& $$content_ref =~ m{
			<AVAILABLE_SERVICES>getFullTxt</AVAILABLE_SERVICES>
			}sxmi ) {

		# Get SFX Object ID
		my $sfx_object_id = $1 if ( $$content_ref =~ m{
			<OBJECT_ID>(\d+?)</OBJECT_ID>
			}sxmi );

		# Define OpenURL metadata format according to the available metadata
		my $sfx_metadata = 'book';
		my $sfx_genre = 'book';
		if ( $$content_ref =~ m{
			<IDENTIFIER>issn:
			}sxmi ) {
			$sfx_genre = 'journal';
			if ( $data_ref->{request_lookup_table}{$req_id}{volume} || $data_ref->{request_lookup_table}{$req_id}{issue} ) {
				$sfx_genre = 'article';
			}
			$sfx_metadata = 'journal';
		}

		# Build OpenURL
		my $uri = URI->new ( config->{sfx}{base_url} );

		my %uri_params;
		$uri_params{url_ver} = 'Z39.88-2004';
		$uri_params{url_ctx_fmt} = 'info:ofi/fmt:kev:mtx:ctx';
		$uri_params{rft_val_fmt} = 'info:ofi/fmt:kev:mtx:' . $sfx_metadata;
		$uri_params{ctx_ver} = 'Z39.88-2004';
		$uri_params{ctx_enc} = 'info:ofi/enc:UTF-8';
		$uri_params{rfr_id} = config->{sfx}{rfr_id};
		$uri_params{'rft.object_id'} = $sfx_object_id;
		$uri_params{'rft.genre'} = $sfx_genre;
		$uri_params{'rft.year'} = $data_ref->{request_lookup_table}{$req_id}{date} if $data_ref->{request_lookup_table}{$req_id}{date};
		$uri_params{'rft.volume'} = $data_ref->{request_lookup_table}{$req_id}{volume} if $data_ref->{request_lookup_table}{$req_id}{volume};
		$uri_params{'rft.issue'} = $data_ref->{request_lookup_table}{$req_id}{issue} if $data_ref->{request_lookup_table}{$req_id}{issue};
		$uri_params{'rft.spage'} = $data_ref->{request_lookup_table}{$req_id}{spage} if $data_ref->{request_lookup_table}{$req_id}{spage};
		$uri_params{'rft.atitle'} = $data_ref->{request_lookup_table}{$req_id}{atitle} if $data_ref->{request_lookup_table}{$req_id}{atitle};
		$uri_params{vid} = 'primo';

		$uri->query_form(\%uri_params);

		$values{id} = $data_ref->{request_lookup_table}{$req_id}{linked_item};
		$values{openURL} = $uri->as_string;

	}
	return %values;
}

true;
