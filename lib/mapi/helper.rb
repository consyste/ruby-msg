module Mapi
	# This is a helper class for {Pst} and {Msg}.
	class Helper
		# @return [String, nil] Encoding name of ANSI string we assume
		attr_reader :ansi_encoding

		# @return [Boolean] Convert all ANSI string to UTF-8
		attr_reader :to_unicode

		# @param ansi_encoding [String]
		# @param to_unicode [Boolean]
		def initialize ansi_encoding=nil, to_unicode=false
			@ansi_encoding = ansi_encoding || "BINARY"
			@to_unicode = to_unicode
		end

		# Convert `ASCII_8BIT` string. Maybe produce UTF_8 string, or arbitrary object
		#
		# Use cases:
		# 
		# - Decode PT_STRING8 in {Pst}
		# - Decode `0x001e` in {Msg}
		# - Decode body (rtf, text) in {PropertySet}
		#
		# @param str [String]
		# @return [Object]
		def convert_ansi_str str
			if @ansi_encoding
				if @to_unicode
					# assume we can convert this text to UTF-8
					begin
						str.force_encoding(@ansi_encoding).encode("UTF-8")
					rescue Encoding::UndefinedConversionError => ex
						# some text are already UTF-8 due to unknown reason
						str.force_encoding("UTF-8").encode("UTF-8")
					end
				else
					str.force_encoding(@ansi_encoding)
				end
			else
				str
			end
		end
	end
end