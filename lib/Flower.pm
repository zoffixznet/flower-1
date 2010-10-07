class Flower;

use Exemel;
use Flower::DefaultModifiers;

has $.template;

has $!tal   is rw = 'tal';
has $!metal is rw = 'metal';
has $!i18n  is rw = 'i18n';

has $!tal-ns   = 'http://xml.zope.org/namespaces/tal';
has $!metal-ns = 'http://xml.zope.org/namespaces/metal';
has $!i18n-ns  = 'http://xml.zope.org/namespaces/i18n';

has @!tal-tags = 'define', 'condition', 'repeat', 'attributes', 'content', 'replace', 'omit-tag';

has @!metal-tags = 'define-macro', 'use-macro', 'define-slot', 'fill-slot';

## Override find with a subroutine that can find templates based off
## of whatever your needs are (multiple roots, extensions, etc.)
has $!find;

## Modifiers, keys are strings, values are subroutines.
has %!modifiers;

## Data, is used to store the replacement data. Is available for modifiers.
has %.data is rw;

## Internal class, used for the 'repeat' object.
class Flower::Repeat {
  has $.index;
  has $.length;

  method number { $.index + 1           }
  method start  { $.index == 0          }
  method end    { $.index == $.length-1 }
  method odd    { $.number % 2 != 0      }
  method even   { $.number % 2 == 0      }

  method inner  { $.index != 0 && $.index != $.length-1 }

  ## Flower exclusive methods below here, make lists and tables easier.
  method every  ($num) { $.number % $num == 0 }
  method never  ($num) { $.number % $num != 0 }
  method lt     ($num) { $.number < $num      }
  method gt     ($num) { $.number > $num      }
  method eq     ($num) { $.number == $num     }
  method ne     ($num) { $.number != $num     }
}

method new (:$find is copy, :$file, :$template is copy) {
  if ( ! $file && ! $template ) { die "a file or template must be specified."; }
  if ! $find {
    $find = sub ($file) {
      if $file.IO ~~ :f { return $file; }
    }
  }
  if $file {
    my $filename = $find($file);
    $template = Exemel::Document.parse(slurp($filename));
  }
  else {
    if $template ~~ Exemel::Document {
      1; # we don't need to do anything.
    }
    elsif $template ~~ Exemel::Element {
      $template = Exemel::Document.new(:root($template));
    }
    elsif $template ~~ Str {
      $template = Exemel::Document.parse($template);
    }
    else {
      die "invalid template type passed.";
    }
  }
  my %modifiers = Flower::DefaultModifiers::all();
  self.bless(*, :$template, :$find, :%modifiers);
}

method !xml-ns ($ns) {
  return $ns.subst(/^xmlns\:/, '');
}

## Note: Once you have parsed, the template will forever be changed.
## You can't parse twice, so don't fark it up!
## You can access the template Exemel::Document object by using the
## $flower.template attribute.
method parse (*%data) {
  ## First we need to set the data.
  %.data = %data;

  ## Next, let's see if the namespaces have been renamed.
  for $.template.root.attribs.kv -> $key, $val {
    if $val eq $!tal-ns {
      $!tal = self!xml-ns($key);
    }
    elsif $val eq $!metal-ns {
      $!metal = self!xml-ns($key);
    }
    elsif $val eq $!i18n-ns {
      $!i18n = self!xml-ns($key);
    }
  }

  ## Okay, now let's parse the elements.
  self!parse-elements($.template.root);
  return ~$.template;
}

## parse-elements, currently only does tal items.
## metal will be added in the next major release.
## i18n will be added at some point in the future.
## also TODO: implement 'on-error'.
method !parse-elements ($xml is rw) {
  ## Due to the strange nature of some rules, we're not using the
  ## 'elements' helper, nor using a nice 'for' loop. Instead we're doing this
  ## by hand. Don't worry, it'll all make sense.
#  if ! $xml.nodes { return; }
  loop (my $i=0; True; $i++) {
    if $i == $xml.nodes.elems { last; }
    my $element = $xml.nodes[$i];
    if $element !~~ Exemel::Element { next; } # skip non-elements.
    %.data<default> = $element.nodes;         # the 'default' keyword.
    self!parse-element($element);
    ## Now we clean up removed elements, and insert replacements.
    if ! defined $element {
      $xml.nodes.splice($i--, 1);
    }
    elsif $element ~~ Array {
      $xml.nodes.splice($i--, 1, |@($element));
    }
    else {
      $xml.nodes[$i] = $element; # Ensure the node is updated.
    }
  }
}

method !parse-element($element is rw) {
  for @!tal-tags -> $tal {
    my $tag = $!tal~':'~$tal;
    self!parse-tag($element, $tag, $tal);
    if $element !~~ Exemel::Element { last; } # skip if we changed type.
  }
## tal:block borrowed from PHPTAL.
  if ($element ~~ Exemel::Element && $element.name eq $!tal~':block') {
    $element = $element.nodes;
  }
## Haven't figured out METAL stuff entirely yet.
# for @metal -> $metal {
#   my $tag = $!metal~':'~$metal;
#   self!parse-tag($element, $tag, $metal);
# }
## Now let's parse any child elements.
  if $element ~~ Exemel::Element {
    self!parse-elements($element);
  }
}

method !parse-tag ($element is rw, $tag, $ns) {
  my $method = 'parse-'~$ns;
  if $element.attribs.exists($tag) {
    self!"$method"($element, $tag);
  }
}

method !parse-define ($xml is rw, $tag) {
  my @statements = $xml.attribs{$tag}.split(/\;\s+/);
  for @statements -> $statement {
    my ($attrib, $query) = $statement.split(/\s+/, 2);
    my $val = self.query($query);
    if defined $val { %.data{$attrib} = $val; }
  }
  $xml.unset($tag);
}

method !parse-condition ($xml is rw, $tag) {
  if self.query($xml.attribs{$tag}, :bool) {
    $xml.unset($tag);
  } else {
    $xml = Nil;
  }
}

method !parse-content ($xml is rw, $tag) {
  $xml.nodes.splice;
  my $node = self.query($xml.attribs{$tag}, :forcexml);
  if defined $node {
    $xml.nodes.push: $node;
  }
  $xml.unset: $tag;
}

method !parse-replace ($xml is rw, $tag) {
  my $text = $xml.attribs{$tag};
  if defined $text {
    $xml = self.query($text, :forcexml); 
  }
  else {
    $xml = Nil;
  }
}

method !parse-attributes ($xml is rw, $tag) {
  my @statements = $xml.attribs{$tag}.split(/\;\s+/);
  for @statements -> $statement {
    my ($attrib, $query) = $statement.split(/\s+/, 2);
    my $val = self.query($query, :noxml);
    if defined $val {
      $xml.set($attrib, $val);
    }
  }
  $xml.unset: $tag;
}

method !parse-repeat ($xml is rw, $tag) { 
  my ($attrib, $query) = $xml.attribs{$tag}.split(/\s+/, 2);
  my $array = self.query($query);
  if (defined $array && $array ~~ Array) {
    if (! %.data.exists('repeat') || %.data<repeat> !~~ Hash) {
      %.data<repeat> = {}; # Initialize the repeat hash.
    }
    $xml.unset($tag);
    my @elements;
    my $count = 0;
    for @($array) -> $item {
      my $newxml = $xml.deep-clone;
      %.data{$attrib} = $item;
      my $repeat = Flower::Repeat.new(:index($count), :length($array.elems));
      %.data<repeat>{$attrib} = $repeat;
      my $wrapper = Exemel::Element.new(:nodes(($newxml)));
      self!parse-elements($wrapper);
      @elements.push: @($wrapper.nodes);
      $count++;
    }
    %.data<repeat>.delete($attrib);
    %.data.delete($attrib);
    $xml = @elements;
  }
  else {
    $xml = Nil;
  }
}

method !parse-omit-tag ($xml is rw, $tag) {
  my $nodes = $xml.nodes;
  my $query = $xml.attribs{$tag};
  if self.query($query, :bool) {
    $xml = $nodes;
  }
  else {
    $xml.unset: $tag;
  }
}

## Query data, this 
method query ($query, :$noxml, :$forcexml, :$bool) {
  if $query eq '' { 
    if ($bool) { return True; }
    else       { return '';   }
  }
  if $query eq 'nothing' { 
    if ($bool) { return False; }
    else       { return '';    }
  }
  if $query ~~ /^\'(.*?)\'$/ { 
      if ($forcexml) {
          return Exemel::Text.new(:text(~$0));
      }
      return ~$0;
  } # quoted string, no interpolation.
  if $query ~~ /^<.ident>+\:/ {
    my ($handler, $subquery) = $query.split(/\:\s*/, 2);
    if %!modifiers.exists($handler) {
      my $data = %!modifiers{$handler}(self, $subquery, :$noxml, :$forcexml, :$bool);
      return self!query-xml($data, :$forcexml, :$noxml);
    }
  }
  my @paths = $query.split('/');
  my $data = self!lookup(@paths, %.data);
  return self!query-xml($data, :$forcexml, :$noxml);
}

## Enforce forcexml and noxml rules for query().
method !query-xml($data, :$forcexml, :$noxml) {
  ## Default rule for forcexml converts non-XML objects into Exemel::Text.
  if ($forcexml && $data !~~ Exemel) {
    return Exemel::Text.new(:text(~$data));
  }
  elsif ($noxml && $data !~~ Str|Numeric) {
    return; ## With noxml set, we only accept Strings or Numbers.
  }
  return $data;
}

## This handles the lookups for query().
method !lookup (@paths is copy, $data) {
  my $path = @paths.shift;
  my $found;
  given $data {
    when Hash {
      if $data.exists($path) {
        $found = .{$path};
      }
    }
    when Array {
      if $path < .elems {
        $found = .[$path];
      }
    }
    default {
      my ($command, *@args) = $path.comb(/ [ \'.*?\' | \S+ ] /); #split(/\s+/);
      if .can($command) {
        ## Let's query those arguments.
        for @args -> $arg is rw {
            $arg = self.query($arg);
        }
        $found = ."$command"(|@args);
      }
      else {
          warn "attempt to access an invalid item.";
      }
    }
  }
  if @paths {
    return self!lookup(@paths, $found);
  }
  return $found;
}

## Add a single modifier routine.
method add-modifier($name, Callable $routine) {
  %!modifiers{$name} = $routine;
}

## Add a bunch of modifiers, mainly used for plugin libraries.
## Example:
##  use Flower;
##  use Flower::Utils::Logic;
##  my $flower = Flower.new(:file('template.xml'));
##  $flower.add-modifiers(Flower::Utils::Logic::all());
##
method add-modifiers(%modifiers) {
  for %modifiers.kv -> $key, $val {
    self.add-modifier($key, $val);
  }
}

