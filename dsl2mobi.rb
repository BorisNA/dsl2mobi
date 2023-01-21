#!/usr/bin/env ruby
# coding: utf-8

if (RUBY_VERSION =~ /^(1\.9|2\.0)/)
  IS_RUBY2 = true
else
  IS_RUBY2 = false
  $KCODE='u'
end

require 'date'
require 'erb'
require 'fileutils'
require 'optparse'
require 'set'

require File.expand_path('../lib/transliteration', __FILE__)
require File.expand_path('../lib/norm_tags', __FILE__)
require File.expand_path('../lib/templates', __FILE__)

FORMS = {}
CARDS = {}
HWDS = Set.new
cards_list = []

$VERSION = '1.3-NB'
$FAST = false
$FORCE = false
$NORMALIZE_TAGS = true
$TRANSLITERATE = true
$PENYIN = false
$HREF_ARROWS = true
$count = 0
$WORD_FORMS_FILE = nil
$DSL_FILE = nil
$HTML_ONLY = false
$OUT_DIR = "."
$IN = nil
$HEADER = true
$OLDINFL = false
$MERGEBODY = false
$SPLIT = false
$REF2INFL = false

# Need more data for other languages as well
$LANG_MAP = {
  "English" => "en",
  "Russian" => "ru",
  "GermanNewSpelling" => "de",
  "German" => "de",
  "French" => "fr",
  "Polish" => "pl",
  "Chinese" => "zh",
  "Ukrainian" => "uk"
}

opts = OptionParser.new

opts.on("-i", "--in DSL_FILE", "convert this DSL file") { |val|
  $DSL_FILE = val
  $stderr.puts "Reading DSL: #{$DSL_FILE}"
}

opts.on("-o", "--out DIR", "convert to directory") { |val|
  $OUT_DIR = val
  $stderr.puts "INFO: Output directory: #{$OUT_DIR}"
  if File.file?($OUT_DIR)
    $stderr.puts "ERROR: Target directory is a file."
    exit
  end
  unless File.exist?($OUT_DIR)
    $stderr.puts "INFO: Output directory doesn't exist, creating..."
    Dir.mkdir($OUT_DIR)
  end
}

opts.on("-w FILE", "--wordforms FILE", "use the word forms from this file") { |val|
  $WORD_FORMS_FILE = val
  $stderr.puts "Using word forms file: #{$WORD_FORMS_FILE}"
}

opts.separator ""
opts.separator "Advanced options:"

opts.on("-l", "--translit true/false", "transliterate Russian headwords (default: true)") { |val|
  $TRANSLITERATE = !!(val =~ /(true|1|on)/i)
}

opts.on("-p", "--penyin true/false", "transliterate Chinese headwords (default: false)") { |val|
  $PENYIN = !!(val =~ /(true|1|on)/i)
  if $PENYIN    
    $LOAD_PATH << File.expand_path('../lib/chinese_pinyin/lib/', __FILE__)
    require 'chinese_pinyin'
  end
}

opts.on("-n", "--normtags true/false", "normalize DSL tags (default: true)") { |val|
  $NORMALIZE_TAGS = !!(val =~ /(true|1|on)/i)
  $stderr.puts "DSL tags normalization: #{$NORMALIZE_TAGS}"
}

opts.on("-a", "--refarrow true/false", "put arrows before links (default: true)") { |val|
  $HREF_ARROWS = !!(val =~ /(true|1|on)/i)
  $stderr.puts "Reference arrows: #{$HREF_ARROWS}"
}

opts.on("--htmlonly true/false", "produce HTML only (default: false)") { |val|
  $HTML_ONLY = !!(val =~ /(true|1|on)/i)
  $stderr.puts "Generate HTML only: #{$HTML_ONLY}"
}

opts.on("-f", "--force", "overwrite existing files") { |val|
  $FORCE = true
}

opts.on("--sample", "generate small sample") { |val|
  $FAST = true
}


opts.on("-t", "--no-title", "do not add card title (header)") { |val|
  $HEADER = false
}

opts.on("-d", "--old-infl", "use old inflection method to allow inflection duplicates on lookup") { |val|
  $OLDINFL = true
}

opts.on("-m", "--merge-body", "merge all body lines to m0") { |val|
  $MERGEBODY = true
}

opts.on("-r", "--refs-to-infl", "add all card refs to infections") { |val|
  $REF2INFL = true
}

opts.on("-s [LINES]", "--split [LINES]", "split output file by LINES lines (default 10000)") { |val|
  $SPLIT = true
  $SPLIT_SIZE = val ? val.to_i : 10000;
}

opts.separator ""
opts.separator "Common options:"

opts.on("-v", "--version", "print version") {
  puts "Dsl2Mobi Converter, ver. #{$VERSION}"
  puts "Copyright (C) 2013 VVSiz"
  exit
}

opts.on("-h", "--help", "print help") {
  puts opts.to_s
  exit
}

opts.separator ""
opts.separator "Example:"
opts.separator "    ruby dsl2mobi.rb -i in.dsl -o result_dir -w forms-EN.txt"
opts.separator "    Converts in.dsl file into result_dir directory, with English wordforms."

rest = opts.parse(*ARGV)
if !rest.empty?
  $stderr.puts "ERROR: Some options are not recognized: \"#{rest.join(', ')}\""
  exit(1)
end

unless $DSL_FILE
  $stderr.puts "ERROR: Input DSL file is not specified"
  $stderr.puts
  $stderr.puts opts.to_s
  exit
end

$stderr.puts "INFO: Russian headwords transliteration: #{$TRANSLITERATE}"
$stderr.puts "INFO: Chinese headwords transliteration (Penyin): #{$PENYIN}"
$stderr.puts "INFO: DSL Tags normalization: #{$NORMALIZE_TAGS}"
$stderr.puts "INFO: Reference arrows in HTML: #{$HREF_ARROWS}"
$stderr.puts "INFO Splitting by #{$SPLIT_SIZE} lines" if $SPLIT


$ARROW = ($HREF_ARROWS ? "↑" : "")

class Card
  def initialize(hwd)
    @hwds, @body, @empty = [hwd], [], []
    # TODO: properly handle headwords with () and {}
    #if @hwd =~ /\{\\\(/
    #  $stderr.puts "WARN: Can't handle headwords with brackets: #{@hwd}"
    #  exit
    #end
  end

  def add_hwd(h)
     @hwds << h
  end
  
  def print_out(io)
    @hwds.each { |hwd|
      print_out_single(hwd, io)
    }
  end
  
  def my_body_is_ready( body_arr )
    # body_arr - array of raw body lines
    # returns tuple [ body_str, hwds ]
    #    body_str - formatted html string to print out
    #    hwds - a list of headwords to add to infections (from refs in the body)
    # handle body
    
    hwds = Set.new()
    
    body_str = body_arr.map { |line|
      line = line.dup
      indent = 0
      m = line.match(/^\[m(\d+)\]/)
      indent = m[1] if m

      # quote any symbol if there is an \ immedately before
      line.gsub!(/\\(.)/, '+_-_+\1+_-_+')

      # \[ and \] -> something else, without [ and ]
      line.gsub!('+_-_+[+_-_+', '+_-_+LBRACKET+_-_+')
      line.gsub!('+_-_+]+_-_+', '+_-_+RBRACKET+_-_+')

      # delete {{comments}}
      line.gsub!(/\{\{.*?\}\}/, '')

      # <<link>> --> [ref]link[/ref]
      line.gsub!('<<', '[ref]')
      line.gsub!('>>', '[/ref]')

      # < and > --> &lt; and &gt;
      line.gsub!('<', '&lt;')
      line.gsub!('>', '&gt;')

      # \[ and \] --> _{_ and _}_
      line.gsub!('\[', '_{_')
      line.gsub!('\]', '_}_')

      # (\#16) --> (#16). in ASIS.
      line.gsub!('\\#', '#')

      # remove trn tags
      line.gsub!(/\[\/?!?tr[ns]\]/, '')

      # remove lang tags
      line.gsub!(/\[\/?lang[^\]]*\]/, '')

      # remove com tags
      line.gsub!(/\[\/?com\]/, '')

      # remove s tags
      line.gsub!(/\[s\](.*?)\[\/s\]/) do |match|
        file_name = $1

        # handle images
        if file_name =~ /.(jpg|jpeg|bmp|gif|tif|tiff)$/
          # hspace="0" align="absbottom" hisrc=
          # %Q{<img hspace="0" vspace="0" align="middle" src="#{$1}"/>}
          %Q{<img hspace="0" hisrc="#{file_name}"/>}
        elsif file_name =~ /.wav$/
          # just ignore it
        else
          $stderr.puts "WARN: Don't know how to handle media file: #{file_name}"
        end
      end

      # remove t tags
      line.gsub!(/\[t\]/, '<!-- T1 -->')
      line.gsub!(/\[\/?t\]/, '<!-- T2 -->')

      # remove m tags
      line.gsub!(/\[\/?m\d*\]/, '')

      # remove * tags
      line.gsub!('[*]', '')
      line.gsub!('[/*]', '')

      if ($NORMALIZE_TAGS)
        line = Normalizer::norm_tags(line)
      end

      # replace ['] by <u>
      line.gsub!("[']", '<u>')
      line.gsub!("[/']", '</u>')

      # bold
      line.gsub!('[b]', '<b>')
      line.gsub!('[/b]', '</b>')

      # italic
      line.gsub!('[i]', '<i>')
      line.gsub!('[/i]', '</i>')

      # underline
      line.gsub!('[u]', '<u>')
      line.gsub!('[/u]', '</u>')

      line.gsub!('[sup]', '<sup>')
      line.gsub!('[/sup]', '</sup>')

      line.gsub!('[sub]', '<sub>')
      line.gsub!('[/sub]', '</sub>')

      line.gsub!('[ex]', '<span class="dsl_ex">')
      line.gsub!('[/ex]', '</span>')

      # line.gsub!('[ex]', '<ul><ul><li><span class="dsl_ex">')
      # line.gsub!('[/ex]', '</span></li></ul></ul>')

      line.gsub!('[p]', '<span class="dsl_p">')
      line.gsub!('[/p]', '</span>')

      # color translation
      line.gsub!('[c tomato]', '[c   red]')
      line.gsub!('[c slategray]', '[c gray]')

      # ASIS:
      line.gsub!(/\[c   red\](.*?)\[\/c\]/, '[c red]<b>\1</b>[/c]')

      # color
      line.gsub!('[c]', '<font color="green">')
      line.gsub!('[/c]', '</font>')
      line.gsub!(/\[c\s+(\w+)\]/) do |match|
        %Q{<font color="#{$1}">}
      end

      # _{_ --> [
      line.gsub!('_{_', '[')
      line.gsub!('_}_', ']')

      # unquote \[ and \]
      line.gsub!('+_-_+LBRACKET+_-_+', '[')
      line.gsub!('+_-_+RBRACKET+_-_+', ']')

      # brack entites?
      line.gsub!('&lbrack;', '[')
      line.gsub!('&rbrack;', ']')

      # unquote any symbol when \ is before it
      line.gsub!('+_-_+', '')

      # handle ref and {{ }} tags (references)
      line.gsub!(/(?:↑\s*)?\[ref(?:\s+dict="(.*?)")?\s*\](.*?)\[\/ref\]/) do |match|
        # $stderr.puts "#{$1} -- #{$2}"
        
        hwds.add( $2 )
        
        %Q{#{$ARROW} <a href="\##{href_hwd($2)}">#{$2}</a>}
      end

      if $MERGEBODY
        %Q{#{line}}
      else
        %Q{<div class="dsl_m#{indent}">#{line}</div>}
      end
    }.join( $MERGEBODY ? " " : "\n" )
    
    if $MERGEBODY
        body_str = %Q{<div class="dsl_m0">#{body_str}</div>}
    end

    return body_str, hwds
  end
  
  def print_out_single(hwd, io)
    if (@body.empty?)
      $stderr.puts "ERROR: Body empty, possibly original file contains multiple headwords for the same card: #{hwd}"
      $stderr.puts "Make sure that there is only one headword for each card no the DSL!"
      exit
    end

    # We need to generate body line first since it will populate additional hrefs->infls
    body_str, add_hwds = my_body_is_ready( @body )

    if not $REF2INFL
        # Do not use additional infections
        add_hwds = Set.new()
    end

    # #0 Prestrip headword etc
    hwd_ref = clean_hwd(hwd)
    hwd_puts = $HEADER ? clean_hwd_to_display(hwd) : ""


    infl_old_str = ""
    infl_new_str = ""
    # #1 Prepare infl patterns (old and new - depending on options)
    if( $OLDINFL )
        ## $stderr.puts "DEBUG: add hwds '#{add_hwds}'"
        ## t = FORMS[hwd_ref]&.union(add_hwds.to_a)&.flatten&.uniq()
        ## $stderr.puts "DEBUG: FORMS '#{t}'"
        forms = FORMS[hwd_ref]&.union(add_hwds.to_a)&.flatten&.uniq&.join(",")
        if( forms )
            infl_old_str = " infl=\"" + forms + "\""
        end
    else
    
        # "new" inflections (word forms)
        if hwd_ref !~ /[-\.'\s]/ and FORMS[hwd_ref]  # got some inflections
            forms = FORMS[hwd_ref]&.union(add_hwds.to_a)&.flatten&.uniq
            if( forms )
                # delete forms that explicitly exist in the dictionary
                forms = forms.delete_if {|form| HWDS.include?(form)}

                if (forms.size > 0)
                    infl_new_str = "  <idx:infl>\n" +
                    forms.map { |el| "    <idx:iform value=\"#{el}\"/>" }.join("\n") +
                        "\n  </idx:infl>\n"
                end
            end

            # $stderr.puts "HWD: #{hwd} -- #{FORMS[hwd].flatten.uniq.join(', ')}"
        end
    end
    
    # #2 Prepare entry header
    entry_str = %Q{
<a name="\##{href_hwd(hwd_ref)}"/>
<idx:entry name="word" scriptable="yes">
<idx:orth value="#{hwd_ref}" #{infl_old_str}><font size="6" color="#002984"><b>#{hwd_puts}</b></font>
#{infl_new_str}</idx:orth>
}.strip


    # #3 Write entry header
    io.puts ""
    io.puts entry_str


    if ($TRANSLITERATE)
        trans = transliterate(hwd)
        if (trans != hwd)
          io.puts %Q{<idx:orth value="#{trans.gsub(/"/, '')}"/>}
        end
    end
    
    if ($PENYIN)
        trans = Pinyin.t(hwd, '')
        if (trans != hwd)
          io.puts %Q{<idx:orth value="#{trans.gsub(/"/, '')}"/>}
        end
    end
    

    io.puts body_str

    # handle end of card
    io.puts "</idx:entry>"
    io.puts ""
    
    io.puts %Q{<div>\n  <img hspace="0" vspace="0" align="middle" src="padding.gif"/>}
    io.puts %Q{  <table width="100%" bgcolor="#992211"><tr><th widht="100%" height="2px"></th></tr></table>\n</div>}
  end

  def << line
    l = line.strip
    if (l.empty?)
      @empty << line
    else
      @body << line.strip
    end
  end
end

def clean_hwd_global(hwd)
  hwd.gsub('\{', '_<_').gsub('\}', '_>_').
      gsub(/\{.*?\}/, '').
      gsub('_<_', '{').gsub('_>_', '}').
      gsub('\(', '(').gsub('\)', ')').strip
end

def clean_hwd_to_display(hwd)
  clean_hwd_global(
    hwd.gsub(/\{\['\]\}(.*?)\{\[\/'\]\}/, '<u>\1</u>') # {[']}txt{[/']} ---> <u>txt</u>
  )
end

def clean_hwd(hwd)
  clean_hwd_global(hwd)
end

def href_hwd(hwd)
  clean_hwd_global(hwd).gsub(/[\s\(\)'"#°!?]+/, '_')
end

def transliterate(hwd)
  Russian::Transliteration.transliterate(hwd)
end

def binary(str)
  if (IS_RUBY2)
    str.force_encoding("binary")
  else
    str
  end
end

def detect_encoding(filename)
  f = File.open(filename, "rb");
  bom = f.read(3)
  f.close
  
  if bom == binary("\xEF\xBB\xBF") # UTF-8
    #$stderr.puts "DETECTED: UTF-8"
    return "UTF-8"
  elsif bom[0, 2] == binary("\xFE\xFF")  # UTF-16BE
    #$stderr.puts "DETECTED: UTF-16BE"
    return "UTF-16BE"
  elsif bom[0, 2] == binary("\xFF\xFE")  # UTF-16LE
    #$stderr.puts "DETECTED: UTF-16LE"
    return "UTF-16LE"
  else
    # By default, assume UTF-8 without BOM.
    $stderr.puts "WARN: Assuming UTF-8 encoding for: #{filename}"
    return "UTF-8"

    # $stderr.puts "Cannot determine encoding for #{filename}"
    # exit(1)
  end
end

def get_read_mode(filename)
  encoding = detect_encoding(filename)
  read_mode = "r";
  if (IS_RUBY2)
    read_mode = "rb:bom|#{encoding}:UTF-8"
  else
    if (encoding != "UTF-8")
      $stderr.puts "ERROR: Wrong encoding for #{filename}: #{encoding}.\nUpgrade to Ruby 2.0 or use UTF-8."
      exit(5)
    end
  end
  read_mode
end

if ($WORD_FORMS_FILE)
  forms_size = 0
  forms_read_mode = get_read_mode($WORD_FORMS_FILE)
  File.open($WORD_FORMS_FILE, forms_read_mode) do |f|
    f.each do |l|
      l.strip!
      stem, forms = l.split(':')
      stem.strip!
      forms.strip!

      unless FORMS[stem]
        forms_size += 1
        FORMS[stem] = []
      end

      FORMS[stem] << forms.split(/\s*,\s*/)
    end
  end
  $stderr.puts "FORMS SIZE: #{forms_size} -- #{FORMS.size}"
else
  $stderr.puts "INFO: Word forms are not enabled (use --wordforms switch to enable)"
end

# get the full list of headwords in the DSL file,
# as well as title, and in- and out- languages.
first = true
in_header = true

read_mode = get_read_mode($DSL_FILE)
$stderr.puts "READ_MODE: #{read_mode}"

File.open($DSL_FILE, read_mode) do |f|
  while (line = f.gets)         # read every line
    if (first && !IS_RUBY2)
      # strip BOM, if it's there
      if line[0, 3] == "\xEF\xBB\xBF" # UTF-8
        line = line[3, line.size - 3]
      elsif line[0, 2] == "\xFE\xFF"  # UTF-16BE
        $stderr.puts "ERROR: Wrong DSL encoding: UTF-16BE"
        exit(1)
      elsif line[0, 2] == "\xFF\xFE"  # UTF-16LE
        $stderr.puts "ERROR: Currently not supported DSL encoding: UTF-16LE"
        $stderr.puts "INFO: Convert the DSL file into UTF-8 before running this script."
        exit(1)
      end
    end
    first = false

    if line =~ /^#/           # ignore comments
      if in_header            # but first, read the header
          res = line.scan(/^#NAME\s+"(.*)"/i)[0]
          $TITLE = res[0] if res
          res = line.scan(/^#INDEX_LANGUAGE\s+"(\w*)"/i)[0]
          $INDEX_LANGUAGE = res[0] if res
          res = line.scan(/^#CONTENTS_LANGUAGE\s+"(\w*)"/i)[0]
          $CONTENTS_LANGUAGE = res[0] if res
      end
      next
    end
    if (line =~ /^[^\t\s]/)   # is headword?
      in_header = false
      hwd = clean_hwd(line.strip)        # strip \n\r from the end
      HWDS << hwd
    end
  end
end

def get_base_name
  File.basename($DSL_FILE).gsub(/(\..*)*\.dsl$/i, '')
end

$stderr.puts "INFO: Generating only a small sample..." if $FAST


card = nil
first = true
ishwd = false

fileno = 0
FILES = [] # Array of filenames to make OPF

File.open($DSL_FILE, read_mode) do |f|

  while ! f.eof?

  # 1. Create output file name
  out_file = File.join($OUT_DIR, get_base_name + '_' + fileno.to_s + '.html')
  if File.exist?(out_file)
    $stderr.print "WARNING: Output file already exists: \"#{out_file}\". "
    if $FORCE
      $stderr.puts "OVERWRITING!"
    else
      $stderr.puts "Use --force to overwrite."
      exit
    end
  end

  FILES << File.basename(out_file)

  $stderr.puts "Generating HTML: #{out_file}"
  File.open(out_file, "w+") do |out|

    # print HTML header first
    # TODO: get the info from the DSL file
    title = $TITLE
    subtitle = "Generated by Dsl2Mobi-#{$VERSION}"
    html_header = ERB.new(HTML_HEADER_TEMPLATE, trim_mode: "%<>")
    out.puts html_header.result(binding)

    while (line = f.gets)         # read every line
      if (first)
        # strip UTF-8 BOM, if it's there
        if line[0, 3] == "\xEF\xBB\xBF"
          line = line[3, line.size - 3]
        end
        first = false
      end
      if line =~ /^#/           # ignore comments
        # puts line
        next
      end
      if (line =~ /^[^\t\s]/)   # is headword?
        hwd = line.strip        # strip \n\r from the end
        if (CARDS[hwd])
            $stderr.puts "ERROR: Original file contains diplicates: #{hwd} #{CARDS[hwd]}"
            exit
        end
        if ishwd                # is previous line headword?
          card.add_hwd(hwd) unless hwd.empty? # add alternate headwords
        else
          card.print_out(out) if card # print out the previous card
          ishwd = true # current line is headword  
          $count += 1
          card = Card.new(hwd)

          break if ($count == 1000 && $FAST)
          break if ($SPLIT && $count == $SPLIT_SIZE)
          #CARDS[hwd] = card
          #cards_list << card
        end
      else
        ishwd = false # the current line is not headword
        card << line if card && line
      end
    end

    # don't forget the very latest card!
    card&.print_out(out) if ( not ishwd && card )

    # end of HTML
    out.puts "</body>"
    out.puts "</html>"
    
    fileno += 1
    $count = 0 
    
  end
  end # while not EOF
end

# copy CSS and image files
FileUtils::cp(File.expand_path('../lib/dic.css', __FILE__), $OUT_DIR, :verbose => false )
FileUtils::cp(File.expand_path('../lib/padding.gif', __FILE__), $OUT_DIR, :verbose => false )

# generate OPF file
opf_file = File.join($OUT_DIR, get_base_name + '.opf')
if File.exist?(opf_file)
  $stderr.print "WARNING: Output file already exists: \"#{opf_file}\". "
  if $FORCE
    $stderr.puts "OVERWRITING!"
  else
    $stderr.puts "Use --force to overwrite."
    exit
  end
end

$stderr.puts "Generating OPF: #{opf_file}"
File.open(opf_file, "w+") do |out|
  # TODO: get the title/langue info from DSL file
  title = $TITLE
  # $stderr.puts "INFO: Title: #{$TITLE}"

  in_lang = $LANG_MAP[$INDEX_LANGUAGE]
  unless in_lang
    $stderr.puts "WARN: Don't know this DSL language string: #{$INDEX_LANGUAGE}. Assuming English."
    $stderr.puts "WARN: Please set the proper languages in the OPF file manually!"
    in_lang = "en"
  else
    $stderr.puts "INFO: Index Language: #{$INDEX_LANGUAGE} (#{in_lang})"
  end
  language = in_lang

  out_lang = $LANG_MAP[$CONTENTS_LANGUAGE]
  unless out_lang
    $stderr.puts "WARN: Don't know this DSL language string: #{$CONTENTS_LANGUAGE}. Assuming English."
    $stderr.puts "WARN: Please set the proper languages in the OPF file manually!"
    out_lang = "en"
  else
    $stderr.puts "INFO: Content Language: #{$CONTENTS_LANGUAGE} (#{out_lang})"
  end

  description = "Generated by Dsl2Mobi-#{$VERSION} on #{Date.today.to_s}."

  # Template iterates over 'FILE'

  opf_content = ERB.new(OPF_TEMPLATE, trim_mode: "%<>")
  out.puts opf_content.result(binding)
end
