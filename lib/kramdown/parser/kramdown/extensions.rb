# -*- coding: utf-8 -*-
#
#--
# Copyright (C) 2009-2010 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown.
#
# kramdown is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++
#

module Kramdown
  module Parser
    class Kramdown

      IAL_CLASS_ATTR = 'class'

      # Parse the string +str+ and extract all attributes and add all found attributes to the hash
      # +opts+.
      def parse_attribute_list(str, opts)
        str.scan(ALD_TYPE_ANY).each do |key, sep, val, id_attr, class_attr, ref|
          if ref
            (opts[:refs] ||= []) << ref
          elsif class_attr
            opts[IAL_CLASS_ATTR] = (opts[IAL_CLASS_ATTR] || '') << " #{class_attr}"
            opts[IAL_CLASS_ATTR].lstrip!
          elsif id_attr
            opts['id'] = id_attr
          else
            val.gsub!(/\\(\}|#{sep})/, "\\1")
            opts[key] = val
          end
        end
      end

      # Update the +ial+ with the information from the inline attribute list +opts+.
      def update_ial_with_ial(ial, opts)
        (ial[:refs] ||= []) << opts[:refs]
        opts.each do |k,v|
          if k == IAL_CLASS_ATTR
            ial[k] = (ial[k] || '') << " #{v}"
            ial[k].lstrip!
          elsif k.kind_of?(String)
            ial[k] = v
          end
        end
      end

      # Parse the generic extension at the current point. The parameter +type+ can either be
      # <tt>:block</tt> or <tt>:span</tt> depending whether we parse a block or span extension tag.
      def parse_extension_start_tag(type)
        orig_pos = @src.pos
        @src.pos += @src.matched_size

        error_block = lambda do |msg|
          warning(msg)
          @src.pos = orig_pos
          add_text(@src.getch) if type == :span
          false
        end

        if @src[4] || @src.matched == '{:/}'
          name = (@src[4] ? "for '#{@src[4]}' " : '')
          return error_block.call("Invalid extension stop tag #{name}found - ignoring it")
        end

        ext = @src[1]
        opts = {}
        body = nil
        parse_attribute_list(@src[2] || '', opts)

        if !@src[3]
          stop_re = (type == :block ? /#{EXT_BLOCK_STOP_STR % ext}/ : /#{EXT_STOP_STR % ext}/)
          if result = @src.scan_until(stop_re)
            body = result.sub!(stop_re, '')
            body.chomp! if type == :block
          else
            return error_block.call("No stop tag for extension '#{ext}' found - ignoring it")
          end
        end

        if !handle_extension(ext, opts, body, type)
          error_block.call("Invalid extension with name '#{ext}' specified - ignoring it")
        else
          true
        end
      end

      def handle_extension(name, opts, body, type)
        case name
        when 'comment'
          @tree.children << Element.new(:comment, body, nil, :category => type) if body.kind_of?(String)
          true
        when 'nomarkdown'
          @tree.children << Element.new(:raw, body, nil, :category => type, :type => opts['type'].to_s.split(/\s+/)) if body.kind_of?(String)
          true
        when 'options'
          opts.select do |k,v|
            k = k.to_sym
            if Kramdown::Options.defined?(k)
              begin
                val = Kramdown::Options.parse(k, v)
                @options[k] = val
                (@root.options[:options] ||= {})[k] = val
              rescue
              end
              false
            else
              true
            end
          end.each do |k,v|
            warning("Unknown kramdown option '#{k}'")
          end
          @tree.children << Element.new(:eob, :extension) if type == :block
          true
        else
          false
        end
      end


      ALD_ID_CHARS = /[\w-]/
      ALD_ANY_CHARS = /\\\}|[^\}]/
      ALD_ID_NAME = /\w#{ALD_ID_CHARS}*/
      ALD_TYPE_KEY_VALUE_PAIR = /(#{ALD_ID_NAME})=("|')((?:\\\}|\\\2|[^\}\2])*?)\2/
      ALD_TYPE_CLASS_NAME = /\.(#{ALD_ID_NAME})/
      ALD_TYPE_ID_NAME = /#(\w[\w:-]*)/
      ALD_TYPE_REF = /(#{ALD_ID_NAME})/
      ALD_TYPE_ANY = /(?:\A|\s)(?:#{ALD_TYPE_KEY_VALUE_PAIR}|#{ALD_TYPE_ID_NAME}|#{ALD_TYPE_CLASS_NAME}|#{ALD_TYPE_REF})(?=\s|\Z)/
      ALD_START = /^#{OPT_SPACE}\{:(#{ALD_ID_NAME}):(#{ALD_ANY_CHARS}+)\}\s*?\n/

      EXT_STOP_STR = "\\{:/(%s)?\\}"
      EXT_START_STR = "\\{::(\\w+)(?:\\s(#{ALD_ANY_CHARS}*?)|)(\\/)?\\}"
      EXT_BLOCK_START = /^#{OPT_SPACE}(?:#{EXT_START_STR}|#{EXT_STOP_STR % ALD_ID_NAME})\s*?\n/
      EXT_BLOCK_STOP_STR = "^#{OPT_SPACE}#{EXT_STOP_STR}\s*?\n"

      IAL_BLOCK = /\{:(?!:|\/)(#{ALD_ANY_CHARS}+)\}\s*?\n/
      IAL_BLOCK_START = /^#{OPT_SPACE}#{IAL_BLOCK}/

      BLOCK_EXTENSIONS_START = /^#{OPT_SPACE}\{:/

      # Parse one of the block extensions (ALD, block IAL or generic extension) at the current
      # location.
      def parse_block_extensions
        if @src.scan(ALD_START)
          parse_attribute_list(@src[2], @alds[@src[1]] ||= Utils::OrderedHash.new)
          @tree.children << Element.new(:eob, :ald)
          true
        elsif @src.check(EXT_BLOCK_START)
          parse_extension_start_tag(:block)
        elsif @src.scan(IAL_BLOCK_START)
          if @tree.children.last && @tree.children.last.type != :blank && @tree.children.last.type != :eob
            parse_attribute_list(@src[1], @tree.children.last.options[:ial] ||= Utils::OrderedHash.new)
            @tree.children << Element.new(:eob, :ial) unless @src.check(IAL_BLOCK_START)
          else
            parse_attribute_list(@src[1], @block_ial = Utils::OrderedHash.new)
          end
          true
        else
          false
        end
      end
      define_parser(:block_extensions, BLOCK_EXTENSIONS_START)


      EXT_SPAN_START = /#{EXT_START_STR}|#{EXT_STOP_STR % ALD_ID_NAME}/
      IAL_SPAN_START = /\{:(#{ALD_ANY_CHARS}+)\}/
      SPAN_EXTENSIONS_START = /\{:/

      # Parse the extension span at the current location.
      def parse_span_extensions
        if @src.check(EXT_SPAN_START)
          parse_extension_start_tag(:span)
        elsif @src.check(IAL_SPAN_START)
          if @tree.children.last && @tree.children.last.type != :text
            @src.pos += @src.matched_size
            attr = Utils::OrderedHash.new
            parse_attribute_list(@src[1], attr)
            update_ial_with_ial(@tree.children.last.options[:ial] ||= Utils::OrderedHash.new, attr)
            update_attr_with_ial(@tree.children.last.attr, attr)
          else
            warning("Found span IAL after text - ignoring it")
            add_text(@src.getch)
          end
        else
          add_text(@src.getch)
        end
      end
      define_parser(:span_extensions, SPAN_EXTENSIONS_START, '\{:')

    end
  end
end
