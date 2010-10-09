#!/usr/bin/env perl6

BEGIN { @*INC.unshift: './lib' }

use Test;
use Flower;

class Person {
    method talk (*@args) {
        my $name = @args.shift || 'weirdo';
        return "Why are you talking to yourself $name?";
    }
}

plan 1;

my $xml = '<?xml version="1.0"?>';

my $template = "<test><item tal:content=\"self/talk 'Tim'\"/></test>";
my $flower = Flower.new(:template($template));

is $flower.parse(:self(Person.new)), $xml~'<test><item>Why are you talking to yourself Tim?</item></test>', 'tal:content with method call';
