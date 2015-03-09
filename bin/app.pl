#!/usr/bin/env perl
use Dancer;
use PrimoServices;
use Plack::Builder;

my $app = sub {
	my $env = shift;
	my $request = Dancer::Request->new( env => $env );
	Dancer->dance($request);
};

builder {
	enable "Plack::Middleware::ServerStatus::Lite",
		path => '/server-status',
		allow => [ '127.0.0.1', '172.28.16.0/24' ],
		scoreboard => 'server-status',
		counter_file => 'server-status/counter';
	$app;
};
