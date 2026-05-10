class Crystalline::BrokenSourceFixer
  # Keep track of opening and closing keywords, and their idents,
  # as they happen in the code.
  # had_content: true if any non-skipped line with deeper indent was seen
  # after this keyword was pushed. Used to decide if macro lines at the
  # same indent should trigger closure.
  record LineInfo,
    line_index : Int32,
    indent : Int32,
    keyword : String,
    had_content : Bool = false

  # Try to fix a broken source code by adding missing "end" and "}"
  # according to indentation.
  def self.fix(source : String) : String
    # Keep a stack of opening keywords.
    # We push to the stack when we find an opening keyword and
    # we pop from the stack when we find a closing keyword,
    # or when we find a wrong indentation.
    stack = [] of LineInfo

    lines = source.lines
    lines.each_with_index do |line, line_index|
      next if line.blank?

      stripped = line.lstrip

      # Skip standalone comment lines — they shouldn't trigger indentation checks
      next if stripped.starts_with?('#')

      # Macro directive lines ({% %}) participate in indent checks but don't
      # push or match keywords. At equal indent they only trigger closure
      # if the block had indented content (had_content).
      # Lines with {{ }} interpolation that aren't pure macro directives
      # are treated as normal code.
      is_macro_line = stripped.starts_with?("{%") || stripped.starts_with?("{% ")

      keyword = is_macro_line ? nil : line_keyword(line)
      indent = line_indent(line)

      # Mark stack entries that have seen indented content
      stack.last?.try { |info|
        if indent > info.indent && !info.had_content
          stack[-1] = info.copy_with(had_content: true)
        end
      }

      unless is_macro_line
        # Detect postfix block keywords (e.g., x = case, base = if)
        if keyword.nil? && stripped.match(/=\s*(case|if|unless)\b/)
          keyword = $1.to_s
        end

        # Detect mid-line 'do' blocks (e.g., array.map do |x|, spawn do)
        if keyword.nil? && stripped.match(/\bdo(\s+(\|.*?\|)?)?\s*$/)
          keyword = "do"
        end

        # Abstract method declarations with return types have no body
        if keyword && !closing_keyword?(keyword) && stripped.starts_with?("abstract def") && stripped.match(/:\s*\w+[\[\],|()\s]*\s*$/)
          keyword = nil
        end
      end

      while true
        last_info = stack.last?
        break unless last_info

        closing_keyword = closing_keyword(last_info)

        # Nothing to fix unless there's a wrong indent.
        # Macro directive lines only trigger closure when:
        # - At strictly lesser indent, OR
        # - At equal indent with had_content, but NOT for blocks that
        #   commonly have same-indent continuations (case/when, if/else).
        if is_macro_line
          if indent < last_info.indent
            # Definitely close
          elsif indent == last_info.indent && last_info.had_content && !last_info.keyword.in?("case", "if", "unless")
            # Close blocks whose body is always indented
          else
            break
          end
        else
          break unless wrong_indent?(indent, keyword, closing_keyword, last_info, line)
        end

        # We have a wrong indentation so we fix/close the opening keyword
        # by adding an "end" (or "}") to it.
        # Walk backwards to find a non-blank, non-comment line.
        # Don't skip macro lines — appending "; end" after {% end %}
        # is valid and avoids placing ends inside macro conditionals.
        target_index = line_index - 1
        while target_index > 0 && (lines[target_index].blank? || lines[target_index].lstrip.starts_with?('#'))
          target_index -= 1
        end

        target_line = lines[target_index]

        lines[target_index] =
          if target_line.blank?
            # If the line is empty we can change it to an end
            # and even use the correct indent.
            "#{(" " * last_info.indent)}#{closing_keyword}"
          else
            insert_before_comment(target_line, "; #{closing_keyword}")
          end

        stack.pop
      end

      # If we found an "end" at exactly the indentation of the last
      # opening keyword, remove it from the stack.
      if last_info && indent == last_info.indent && keyword == closing_keyword(last_info)
        # all good: an end is closing an opening keyword
        stack.pop
        next
      end

      # Push to the stack if we found an opening keyword.
      if keyword && !closing_keyword?(keyword)
        stack << LineInfo.new(
          line_index: line_index,
          indent: indent,
          keyword: keyword
        )
      end
    end

    while (line_info = stack.pop?)
      # Walk backwards from end to find a non-blank line.
      # Don't skip macro lines here — appending "; end" after {% end %}
      # is valid and avoids placing ends inside macro conditionals.
      target_index = lines.size - 1
      while target_index > 0 && lines[target_index].blank?
        target_index -= 1
      end

      target_line = lines[target_index]
      lines[target_index] =
        if target_line.blank?
          "#{(" " * line_info.indent)}#{closing_keyword(line_info)}"
        else
          insert_before_comment(target_line, "; #{closing_keyword(line_info)}")
        end
    end

    lines.join("\n")
  end

  private def self.line_indent(line : String) : Int32?
    non_whitespace_char_index = line.each_char_with_index do |char, i|
      next if char.whitespace?
      break i
    end

    if non_whitespace_char_index
      non_whitespace_char_index
    else
      0
    end
  end

  private def self.line_keyword(line : String) : String?
    # Strip trailing inline comments so patterns with $ anchors
    # and ends_with? work correctly on commented lines.
    line = strip_inline_comment(line)

    if line.starts_with?(/\s*
      (
        if |
        unless |
        while |
        until |
        case |
        ((private|protected)\s+)?def |
        (private\s+)?(abstract\s+)?class |
        (private\s+)?(abstract\s+)?struct |
        (private\s+)?module |
        (private\s+)?enum |
        (private\s+)?lib |
        (private\s+)?union |
        (private\s+)?macro |
        (private\s+)?annotation
      )\s/x)
      $1
    elsif line.matches?(/\s*begin\s*$/)
      "begin"
    elsif line.ends_with?(/\s*do(\s+\|[^|]+\|)?\s*$/)
      "do"
    elsif line.ends_with?(/\s*\)\s*{(\s*\|[^|]+\|)?\s*$/)
      "{"
    elsif line.ends_with?(/\s*[\w\d]\s*{(\s*\|[^|]+\|)?\s*$/)
      "{"
    elsif line.matches?(/^\s*end\b/)
      "end"
    elsif line.matches?(/^\s*}(\s*$|[.)\],;])/)

      "}"
    elsif line.matches?(/\s*else\s*$/)
      "else"
    elsif line.starts_with?(/\s*elsif\s+/)
      "elsif"
    elsif line.starts_with?(/\s*when\s+/)
      "when"
    elsif line.starts_with?(/\s*in\s+/)
      "in"
    elsif line.starts_with?(/\s*rescue(\b|\s)/)
      "rescue"
    elsif line.matches?(/\s*ensure\s*$/)
      "ensure"
    else
      nil
    end
  end

  private def self.closing_keyword(line_info : LineInfo)
    closing_keyword(line_info.keyword)
  end

  private def self.closing_keyword(keyword : String)
    keyword == "{" ? "}" : "end"
  end

  # Whether a line should be skipped when walking backwards to find
  # a suitable target for "; end" insertion.
  private def self.skip_line?(line : String) : Bool
    return true if line.blank?
    stripped = line.lstrip
    return true if stripped.starts_with?('#')
    return true if stripped.starts_with?("{%") || stripped.starts_with?("{% ")
    false
  end

  # Insert text before any trailing inline comment, handling strings.
  private def self.insert_before_comment(line : String, insertion : String) : String
    comment_index = find_comment_index(line)

    if comment_index
      code_part = line[0...comment_index].rstrip
      comment_part = line[comment_index..]
      "#{code_part}#{insertion} #{comment_part}"
    else
      "#{line}#{insertion}"
    end
  end

  # Strip trailing inline comment, returning just the code portion (rstripped).
  private def self.strip_inline_comment(line : String) : String
    comment_index = find_comment_index(line)
    comment_index ? line[0...comment_index].rstrip : line
  end

  # Find the index of a trailing `#` comment that isn't inside a string.
  # Returns nil if no inline comment is found.
  private def self.find_comment_index(line : String) : Int32?
    in_single_quote = false
    in_double_quote = false
    escape_next = false

    line.each_char_with_index do |char, i|
      if escape_next
        escape_next = false
        next
      end

      if char == '\\' && (in_single_quote || in_double_quote)
        escape_next = true
        next
      end

      if char == '"' && !in_single_quote
        in_double_quote = !in_double_quote
        next
      end

      if char == '\'' && !in_double_quote
        in_single_quote = !in_single_quote
        next
      end

      if char == '#' && !in_single_quote && !in_double_quote
        return i
      end
    end

    nil
  end

  private def self.closing_keyword?(keyword : String)
    keyword.in?("end", "else", "elsif", "when", "in", "rescue", "ensure", "}")
  end

  private def self.wrong_indent?(
    indent : Int32,
    keyword : String?,
    closing_keyword : String?,
    last_info : LineInfo,
    line : String,
  )
    # If the indent is less than the opening one it's definitely wrong.
    if indent < last_info.indent
      return true
    end

    # If the indent is greater, it's all good (it's probably content inside that definition)
    if indent > last_info.indent
      return false
    end

    # All good if it's the closing keyword to an opening definition
    if keyword == closing_keyword
      return false
    end

    # Some special cases: else and elsif have the same indentation as
    # the opening keyword but they don't close it (more content is expected
    # to come until the "end" keyword)
    if last_info.keyword == "if" && keyword == "else"
      return false
    end

    if last_info.keyword == "if" && keyword == "elsif"
      return false
    end

    if last_info.keyword == "unless" && keyword == "else"
      return false
    end

    if last_info.keyword == "case" && keyword.in?("when", "in", "else")
      return false
    end

    if last_info.keyword.in?("begin", "def", "do") && keyword.in?("rescue", "ensure", "else")
      return false
    end

    # A def signature can also be defined in multiple lines, like this:
    #
    # def foo(
    #   x, y
    # )
    #
    # In that case we don't want to consider the closing parentheses
    # as having wrong indentation.
    if last_info.keyword == "def" && line.strip == ")"
      return false
    end

    true
  end
end
