#!/usr/bin/env perl
use Dancer;
use PrimoServices;
use Plack::Builder;

builder {
	enable 'Plack::Middleware::Deflater';
	enable 'Plack::Middleware::ServerStatus::Lite',
		path => '/server-status',
		allow => [ '127.0.0.1', '172.28.16.0/24' ],
		scoreboard => 'server-status',
		counter_file => 'server-status/counter' if config->{environment} eq 'production';
	dance;
};
