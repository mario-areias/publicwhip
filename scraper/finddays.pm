# $Id: finddays.pm,v 1.5 2004/03/15 12:09:50 frabcus Exp $
# Scans various index pages in various ways to hunt down the content
# for each day in text of Hansard beneath them all.  Stores URLs
# of the first page of content.

# The Public Whip, Copyright (C) 2003 Francis Irving and Julian Todd
# This is free software, and you are welcome to redistribute it under
# certain conditions.  However, it comes with ABSOLUTELY NO WARRANTY.
# For details see the file LICENSE.html in the top level of the source.

package finddays;
use strict;

use HTML::TokeParser;
use HTTP::Status;
use Date::Parse;
use divisions;
use error;

sub hunt_within_month_or_volume
{
    my $dbh = shift;
    my $agent = shift;
    error::die("Error getting month/volume index URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
    my $content = $agent->{content}; # put in local variable to copy it out of the agent, so agent can walk recursively
    my $p = HTML::TokeParser->new(\$content);

    my $already_have = 0;

    # Find links to something with Debate in the text
    my $c = 1;
    while (my @link = $agent->find_link(text_regex => qr/Debate/i, n => $c))
    {
        $_ = $link[0][0];
        # Remove CR/LF from in URL (should be done in WWW::Mechanize?)
        s/\r//g;
        s/\n//g;
        #$agent->_push_page_stack(); # needed in some versions of WWW::Mechanize
        $agent->get($_);
        error::die("Error getting debate index URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
        error::log("Debate found", $agent->uri(), error::USEFUL);

        # Following through to body text (from index)
        if (!(defined $agent->follow_link(url_regex => qr#debtext#i, n => 1)))
        {
            error::warn("Couldn't find debate text from index", $agent->uri());
            $c++;
            $agent->back();
            next;
        }
        error::die("Error getting debate first page URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
        my $first_page = $agent->uri();
        $first_page =~ s/#.*$//; # remove inwards anchors after the hash

        # Find either of these, and extract date:
        # <meta name="Date" content ="20 Jun 2001">
        # <title>House of Commons Hansard Debates for 30 Nov 1998 (pt 1)</title>
        my $content = $agent->{content};
        my $p = HTML::TokeParser->new(\$content);
        my $date = undef;
        my $date_english = undef;
        my $token;
        while ($token = $p->get_tag("meta", "title")) 
        {
            if ($token->[0] eq "meta")
            {
                if ($token->[1]{name} and $token->[1]{name} eq "Date")
                {
                    $date_english = $token->[1]{content};
                    last;
                }
            }
            else # title
            {
                $_ = $p->get_trimmed_text("/title");
                if (m/for \b(\d\d? [A-Z][a-z][a-z] \d\d\d\d\b)/)
                {
                    $date_english = $1;
                    last;
                }
            }
        }
        $date = str2time($date_english);
        error::die("Couldn't find date", $agent->uri()) unless defined $date;
        error::log("Date is $date_english $date", $agent->uri(), error::CHITTER);

        # See if we already have it
        my $sth = db::query($dbh, "select first_page_url from pw_hansard_day 
            where day_date = FROM_UNIXTIME(?)", $date);
        error::die("Found more than one existing URL", $agent->uri()) if $sth->rows > 1;
        if ($sth->rows > 0)
        { 
            my @data = $sth->fetchrow_array();
            if ($data[0] ne $first_page)
            {
                error::die("Different URL " . $data[0] . " already in database", $agent->uri());
            }
            $already_have++;
        }
        else
        {
            # Add the URL into a table of dates-->URLs
            db::query($dbh, "insert into pw_hansard_day 
                (day_date, first_page_url) values
                (FROM_UNIXTIME(?), ?)", $date, $first_page);
        }


        $agent->back();
        $agent->back();
        $c++;
    }
    return $already_have;
}

sub recent_months
{
    my $dbh = shift;
    my $agent = shift;
    my $skip_forwards = shift;

    error::die("Error getting month URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
    my $content = $agent->{content}; # put in local variable to copy it out of the agent, so agent can walk recursively
    my $p = HTML::TokeParser->new(\$content);

    # Find links to something with this form (these are the front page months):
    # http://www.publications.parliament.uk/pa/cm/cmhn****.htm
    my $c = 1;
    my $already_have = 0;
    while ($agent->follow_link(url_regex => qr#cmhn\d\d\d\d.htm#i, n => $c))
    {
        if (defined $skip_forwards && $agent->uri() !~ m/$skip_forwards/)
        {
            error::log("Skipping month", $agent->uri(), error::USEFUL);
        }
        else
        {
            undef $skip_forwards;

            error::log("Month found", $agent->uri(), error::USEFUL);
            $already_have += finddays::hunt_within_month_or_volume($dbh, $agent);
        }
        $agent->back();
        $c++;

        # Stop if we have got to what we already have
        last if $already_have > 0;
    }
}

sub hunt_within_session
{
    my $dbh = shift;
    my $agent = shift;
    error::die("Error getting volume list URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
    my $content = $agent->{content}; # put in local variable to copy it out of the agent, so agent can walk recursively
    my $p = HTML::TokeParser->new(\$content);

    # Find links whose text says "Volume ***"
    my $c = 1;
    while ($agent->follow_link(text_regex => qr/Volume \d\d\d/i, n => $c))
    {
        error::log("Volume found", $agent->uri(), error::USEFUL);
        finddays::hunt_within_month_or_volume($dbh, $agent);
        error::log("Volume done", $agent->uri(), error::USEFUL);
        $agent->back();
        $c++;
    }
}

sub recent_sessions
{
    my $dbh = shift;
    my $agent = shift;
    my $skip_forwards = shift;
    my $stop_at = shift;

    error::die("Error getting session URL " . $agent->response->status_line, $agent->uri()) unless $agent->success;
    my $content = $agent->{content}; # put in local variable to copy it out of the agent, so agent can walk recursively
    my $p = HTML::TokeParser->new(\$content);

    # Find links to something with this form (session archives):
    # http://www.publications.parliament.uk/pa/cm/cmse****.htm
    my $c = 1;
    while ($agent->follow_link(url_regex => qr#cmse\d\d\d\d.htm#i, n => $c))
    {
        my $url = $agent->uri();
        if (defined $skip_forwards && $agent->uri() !~ m/$skip_forwards/)
        {
            error::log("Skipping session", $agent->uri(), error::USEFUL);
        }
        else
        {
            undef $skip_forwards;
            error::log("Session found", $agent->uri(), error::USEFUL);
            finddays::hunt_within_session($dbh, $agent);
            error::log("Session done", $agent->uri(), error::USEFUL);
        }
        $agent->back();

        # Stop if reach end point
        last if $url =~ m/$stop_at/;
        $c++;
    }
}

1;
