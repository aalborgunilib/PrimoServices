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
	
	my $data;

	# Parse and reply to the request
	#$data = PrimoServices::Dispatcher::handle_request();
	
	try {
		my $execution_time = timeit( 1, sub{
			$data = PrimoServices::Dispatcher::handle_request();
		});

		# Calculate the total execution time of the call
		$data->{appExecutionTime} = sprintf "%.3fs", $execution_time->real;
	}
	catch {
		status 500;
		$data->{error} = 'PrimoServices';
		$data->{exception} = $_;
	};

	# Insert the request into the response (in development)
	$data->{request} = params if config->{environment} eq 'development';

	# Delete request_lookup_table (outside development)
	delete $data->{request_lookup_table} if config->{environment} ne 'development';

	# Count requested and returned number of IDs
	$data->{totalItems}	= param_array 'id';
	$data->{totalItemsReturned} = @{$data->{items}};

	# Name and version
	$data->{appName} = config->{appname} . ' ' . $VERSION->normal();

	# Set the serializer to either JSONP or JSON
	if ( params->{callback} ) {
		set serializer => 'JSONP';
	}
	else {
		set serializer => 'JSON';
	}

	# Serialize...
	return $data;
};

true;
