package PrimoServices::Dispatcher;
use 5.10.0;
use Dancer ':syntax';
use Dancer::Exception ':all';

use PrimoServices::Parsers ':all';

use HTTP::Async();
use HTTP::Request();
use HTTP::Headers();
use URI();
use CHI();
use locale;
use Digest::SHA();
use List::MoreUtils();
use Data::Dumper();

# Setup $cache CHI object
my $uid = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
my $cache = CHI->new(
	namespace => __PACKAGE__,
	driver => config->{caching}{chi_driver},
	#driver => 'Null',
	root_dir => config->{caching}{chi_root_dir} . '_' . $uid,
	depth => config->{caching}{chi_depth},
	expires_in => config->{caching}{default_expires_in},
	);

# Setup $async HTTP::Async object
my $async = HTTP::Async->new(
	slots => config->{http_async}{slots},
	timeout => config->{http_async}{max_request_time}
	);
my $headers = HTTP::Headers->new(
	Accept_Encoding => 'gzip',
	Accept_Charset => 'utf-8',
	User_Agent => config->{http_async}{user_agent}
	);


# We will use the given/when 'switch' feature of perl 5.10.0
no if $] >= 5.018, warnings => "experimental";
use feature 'switch';


sub handle_request {
	# Get URL parameters
	my %params = request->params;

	# The response that we are building
	my %data;

	# Dispatch initial web service requests
	request_webservices(\%params,\%data);

	# Retrieve responses (and dispatch further web service requests)
	retrieve_webservices(\%data);


	return \%data;
}

sub request_webservices {
	my $params_ref = shift;
	my $data_ref = shift;

	# Our helper lookup-table which will link request id numbers to the request type and key
	my %request_lookup_table;

	#
	# Primo Central
	#

	# Query Primo Central (not in case of blended search or call from a Primo Central tab)
	if ( $params_ref->{scope} && $params_ref->{scope} !~ m{primo_central_multiple_fe} ) {

		# Turn the query string into an unique id
		my $key;
		{
			# Avoid problems with UTF-8 strings
			use bytes;
			$key = 'primocentral' . Digest::SHA::sha1_hex( $params_ref->{query} . $params_ref->{scope} );
		}

		unless ( $cache->is_valid($key) && ! defined params->{nocaching} ) {
			# Not in cache
			my $uri = URI->new( config->{primo}{'api'} . config->{primo}{x_search_brief} );

			$uri->query_form(
				institution => config->{primo}{institution},
				pcAvailability => 1,
				indx => 1,
				bulkSize => 1,
				json => 'true',
				loc => 'adaptor,primo_central_multiple_fe',
				query => 'any,contains,' . param 'query' );

			my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

			$request_lookup_table{$req_id} = { type => 'primocentral', uri => $uri->as_string, key => $key };
		}
		else {
			# Get from cache
			$data_ref->{primoCentral} = $cache->get($key);
		}
	}

	#
	# Keywords
	#

	# Query for each individual keyword in the search string
	if ( $params_ref->{query} ) {
		my $query = $params_ref->{query};

		# Normalize query string
		$query =~ s{
			# Remove 's
			's}{}gsxmi;

		$query =~ s{ 
			# Concatenate ' parts
			'}{}gsxm;

		$query =~ s{
			# Remove non words
			[\W]}{ }gsxm;

		# Replace any horizontal white space with a single space
		$query =~ s{\h+}{ }gsxm;

		# Remove heading and / or tailing white space
		$query =~ s{^\s|\s$}{}gsxm;

		my @keywords;

		foreach my $keyword ( split / /, $query ) {
			# Skip short keywords
			if ( length($keyword) < 3 ) {
				push @{$data_ref->{keywordSearch}}, { $keyword => '...' };
				next;
			}

			# Turn the keyword query into an unique id
			my $key;
			{
				# Avoid problems with UTF-8 strings
				use bytes;
				$key = 'keyword' . Digest::SHA::sha1_hex( $keyword . $params_ref->{scope} . '' );
			}

			unless ( $cache->is_valid($key) && ! defined params->{nocaching} ) {
				# Create a list of individual search scopes
				my @search_scopes;
				while ( $params_ref->{scope} =~ m{scope:\((.*?)\)}gsxm ) {
					push @search_scopes, $1;
				}
				my $scope;
				$scope = 'local,scope:(' . join(',', @search_scopes) . ')' if @search_scopes;

				# Not in cache
				my $uri = URI->new( config->{primo}{'api'} . config->{primo}{x_search_brief} );

				# Build hash of query parameters
				my %query_params;
				$query_params{institution} = config->{primo}{institution};
				$query_params{indx} = 1;
				$query_params{bulkSize} = 1;
				# Is it a blended search scope?
				if ( $scope && $params_ref->{scope} =~m {primo_central_multiple_fe} ) {
					$query_params{loc} = [ $scope, 'adaptor,primo_central_multiple_fe' ];
				}
				# Is it a local search scope?
				elsif ( $scope ) {
					$query_params{loc} = $scope;
				}
				# Then it is Primo Central
				else {
					$query_params{loc} = 'adaptor,primo_central_multiple_fe';	
				}
				$query_params{query} = 'any,exact,' . $keyword;
				$query_params{json} = 'true';

				$uri->query_form(\%query_params);

				my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

				$request_lookup_table{$req_id} = { type => 'keyword', keyword => $keyword, key => $key, uri => $uri->as_string };
			}
			else {
				# Get from cache
				push @{$data_ref->{keywordSearch}}, $cache->get($key);
			}
		}
	}

	#
	# Primo records
	#

	# Array of the responses for each individual IDs we are gathering information about
	my @items;

	# Iterate through each ID given
	foreach my $id ( param_array 'id' ) {

		# Skip further handling of Primo Central records
		if ( $id =~ m {
			# Primo Central records are prefixed by 'TN_'
			^TN_}sxm ) {
			push @items, { id => $id, primoStatus => 'Not a local record' };
			next;
		}

		# If the local record is a frbr group
		if ( $id =~ m {
			# frbr groups are prefixed by 'frbg' followed by the id number
			^(?:frbg)(.*)
			}sxm) {
			my $frbg = $1;

			unless ( $cache->is_valid($id) && ! defined params->{nocaching} ) {
				# Not in cache
				my $uri = URI->new( config->{primo}{'api'} . config->{primo}{x_search_brief} );

				$uri->query_form(
					institution => config->{primo}{institution},
					loc => 'local',
					indx => 1,
					bulkSize => 1000,
					query => 'facet_frbrgroupid,exact,' . $frbg,
					json => 'true' );

				my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

				$request_lookup_table{$req_id} = { type => 'frbg', key => $id, uri => $uri->as_string };
			}
			else {
				# Get from cache
				push @items, $cache->get($id);
			}
		}
		# Then this is a single, local record
		else {
			unless ( $cache->is_valid($id) && ! defined params->{nocaching} ) {
				# Not in cache
				my $uri = URI->new( config->{primo}{'api'} . config->{primo}{x_search_full} );

				$uri->query_form(
					institution => config->{primo}{institution},
					indx => 1,
					bulkSize => 1,
					getDelivery => 'true',
					query => 'any,contains,',
					docId => $id,
					json => 'true' );

				my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

				$request_lookup_table{$req_id} = { type => 'record', key => $id, uri => $uri->as_string };
			}
			else {
				# Get from cache
				my $item = $cache->get($id);
				push @items, $item;
				# Get JournalTOCs from cache
				if ( $item->{metadata}{issn} ) {
					my $key = 'issn' . lc $item->{metadata}{issn};
					my $item = $cache->get($key);
					if ( $item && $item->{id} ) {
						push @{$data_ref->{journalTOCs}}, $item;
					}
				}
				# Get GoogleBooks from cache
				if ( $item->{metadata}{isbn} ) {
					my $key = 'isbn' . lc $item->{metadata}{isbn};
					my $item = $cache->get($key);
					if ( $item && $item->{id} ) {
						push @{$data_ref->{googleBooks}}, $item;
					}
				}
				# Get RSI from cache
				if ( $item->{id} ) {
					my $key = 'rsi' . $item->{id};
					my $item = $cache->get($key);
					if ( $item && $item->{id} ) {
						push @{$data_ref->{rsi}}, $item;
					}
				}
			}
		}
	}

	$data_ref->{items} = \@items;
	$data_ref->{request_lookup_table} = \%request_lookup_table;
}

sub retrieve_webservices {
	my $data_ref = shift;

	# Wait until a response has arrived
	while ( my ($response, $req_id) = $async->wait_for_next_response ) {

		# Is it a success?
		if ( $response->message eq 'OK' ) {
			
			my $content = $response->decoded_content;

			given ( $data_ref->{request_lookup_table}{$req_id}{type} )			 {
				when ( /record/ ) {
					my %values = parse_record(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{items}}, \%values;
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);

					#
					# Google Books
					#

					# Send to Google Books API if we have an ISBN numer and the item is in print
					if ( $values{metadata}{isbn} && grep /Physical Item/, @{$values{delcategory}} ) {

						my $key = 'isbn' . lc $values{metadata}{isbn};
						$key =~ s/-//g;

						unless ( $cache->is_valid($key) && ! defined params->{nocaching} ) {
							my ($req_id, $uri) = query_googlebooks($values{metadata}{isbn});
							$data_ref->{request_lookup_table}{$req_id} = {
								type => 'googlebooks',
								key => $key,
								isbn => $values{metadata}{isbn},
								uri => $uri,
								linked_item => $values{id}
							};
						}
						else {
							# Get from cache
							push @{$data_ref->{googleBooks}}, $cache->get($key);
						}
					}

					#
					# JournalTOCs
					#

					# Send to JournalTOCs if we have an ISSN number and the record is a journal
					if ( $values{metadata}{issn} && $values{type} eq 'journal' ) {

						my $key = 'issn' . lc $values{metadata}{issn};

						unless ( $cache->is_valid($key) && ! defined params->{nocaching} ) {
							my ($req_id, $uri) = query_journaltocs($values{metadata}{issn});
							$data_ref->{request_lookup_table}{$req_id} = {
								type => 'journaltocs',
								key => $key,
								issn => $values{metadata}{issn},
								uri => $uri,
								linked_item => $values{id}
							};
						}
						else {
							# Get from cache
							push @{$data_ref->{journalTOCs}}, $cache->get($key);
						}
					}

					#
					# RSI
					#

					# Send to SFX RSI API to check for online resource
					if ( defined @{$values{delcategory}}[0]
						&& @{$values{delcategory}} == 1 && @{$values{delcategory}}[0] eq 'Physical Item' 
						&& ($values{metadata}{isbn} || $values{metadata}{issn}) ) {

						my $key = 'rsi' . $values{id};

						unless ( $cache->is_valid($key) && ! defined params->{nocaching} ) {
							my ($req_id, $uri) = query_rsi(\%values);
							$data_ref->{request_lookup_table}{$req_id} = {
								type => 'rsi',
								key => $key,
								uri => $uri,
								linked_item => $values{id},
								atitle => $values{metadata}{atitle},
								spage => $values{metadata}{spage},
								date => $values{metadata}{date},
								volume => $values{metadata}{volume},
								issue => $values{metadata}{issue},
							};
						}
						else {
							# Get from cache
							push @{$data_ref->{rsi}}, $cache->get($key);
						}
					}
				}
				when ( /frbg/ ) {
					my %values = parse_frbg(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{items}}, \%values;
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
				when ( /keyword/ ) {
					my %values = parse_keyword(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{keywordSearch}}, \%values;
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
				when ( /primocentral/ ) {
					my %values = parse_primocentral(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					$data_ref->{primoCentral} = \%values;
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
				when ( /googlebooks/ ) {
					my %values = parse_googlebooks(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{googleBooks}}, \%values if $values{id};
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
				when ( /journaltocs/ ) {
					my %values = parse_journaltocs(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{journalTOCs}}, \%values if $values{id};
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
				when ( /rsi/ ) {
					my %values = parse_rsi(
						$data_ref,
						\$content,
						$data_ref->{request_lookup_table}{$req_id}{key},
						$req_id );
					push @{$data_ref->{rsi}}, \%values if $values{id};
					$cache->set($data_ref->{request_lookup_table}{$req_id}{key}, \%values);
				}
			}
		}
		# There was an error
		else {
			push @{$data_ref->{errors}}, {
				key => $data_ref->{request_lookup_table}{$req_id}{key},
				status => $response->status_line
			};
		}

	}
}

#
# Subs
#

sub query_googlebooks {
	my $isbn = shift;

	my $uri = URI->new( config->{google_books}{api} );

	$uri->query_form(
		key => config->{google_books}{password},
		filter => 'partial',
		country => config->{google_books}{country},
		q => 'isbn:' . $isbn
		);

	my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

	return $req_id, $uri->as_string;
}

sub query_journaltocs {
	my $issn = shift;

	my $uri = URI->new( config->{journaltocs}{api} . $issn );

	$uri->query_form(
		user => config->{journaltocs}{password},
		);

	my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

	return $req_id, $uri->as_string;
}

sub query_rsi {
	my $values_ref = shift;
	
	my $uri = URI->new ( config->{sfx}{rsi_api} );

	# build the RSI API xml payload
	my $rsi_request = '<?xml version="1.0" ?>';
	$rsi_request .= '<IDENTIFIER_REQUEST VERSION="1.0" xsi:noNamespaceSchemaLocation="ISSNRequest.xsd" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">';
	$rsi_request .= '<IDENTIFIER_REQUEST_ITEM>';
	# add every single ISBN and ISSN number
	foreach ( @{$values_ref->{metadata}{'@isbn'}} ) {
		$rsi_request .= '<IDENTIFIER>isbn:' . $_ . '</IDENTIFIER>' if $_;
	}
	foreach ( @{$values_ref->{metadata}{'@issn'}} ) {
		$rsi_request .= '<IDENTIFIER>issn:' . $_ . '</IDENTIFIER>' if $_;
	}
	$rsi_request .= '<YEAR>' . $values_ref->{metadata}{date} . '</YEAR>' if $values_ref->{metadata}{date};
	$rsi_request .= '<VOLUME>' . $values_ref->{metadata}{volume} . '</VOLUME>' if $values_ref->{metadata}{volume};
	$rsi_request .= '<ISSUE>' . $values_ref->{metadata}{issue}. '</ISSUE>' if $values_ref->{metadata}{issue};
	$rsi_request .= '</IDENTIFIER_REQUEST_ITEM>';
	$rsi_request .= '</IDENTIFIER_REQUEST>';

	$uri->query_form(
		request_xml => $rsi_request
		);

	my $req_id = $async->add(HTTP::Request->new( GET => $uri, $headers ));

	return $req_id, $uri->as_string;
}

true;
