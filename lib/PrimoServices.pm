package PrimoServices;
use Dancer 1.3132 ':syntax';
use Dancer::Exception ':all';

use PrimoServices::Dispatcher;

use Time::HiRes();
use Benchmark(':hireswallclock');

# http://semver.org/
# X.Y.Z (Major.Minor.Patch)
use version; our $VERSION = version->declare("v2.2.0");

#
# Route handlers
#

get qr{.*} => sub {
	
	my $data_ref;

	# Parse and reply to the request
	#$data_ref = PrimoServices::Dispatcher::handle_request();
	
	try {
		my $execution_time = timeit( 1, sub{
			$data_ref = PrimoServices::Dispatcher::handle_request();
		});

		# Calculate the total execution time of the call
		$data_ref->{appExecutionTime} = sprintf "%.3fs", $execution_time->real;
	}
	catch {
		status 500;
		$data_ref->{error} = 'PrimoServices';
		$data_ref->{exception} = $_;
	};

	# Insert the request into the response (in development)
	$data_ref->{request} = params if config->{environment} eq 'development';

	# Delete request_lookup_table (outside development)
	delete $data_ref->{request_lookup_table} if config->{environment} ne 'development';

	# Count requested and returned number of IDs
	$data_ref->{totalItems}	= param_array 'id';
	$data_ref->{totalItemsReturned} = @{$data_ref->{items}};

	# Name and version
	$data_ref->{appName} = config->{appname} . ' ' . $VERSION->normal();

	# Set the serializer to either JSONP or JSON
	if ( params->{callback} ) {
		set serializer => 'JSONP';
	}
	else {
		set serializer => 'JSON';
	}

	# Serialize...
	return $data_ref;
};

true;
