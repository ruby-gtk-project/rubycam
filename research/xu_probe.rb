#!/usr/bin/env ruby
# Extension-unit reconnaissance for the OBSBOT Tiny 2.
#
# Dumps every selector the XU descriptor advertises (unit 2, selectors
# 0x01-0x10 + 0x13) with GET_INFO / GET_LEN / GET_CUR. Two uses:
#
#   ruby research/xu_probe.rb                 # print the map
#   ruby research/xu_probe.rb baseline.txt    # save a full 60-byte dump
#
# The saved dump is a reverse-engineering baseline: enable the microphone
# once via OBSBOT Center on another machine, replug the camera here, run
# this again into a second file, and `diff` them. Any selector that
# changed is a persistent setting — a candidate for the stored audio
# (or other) flag that can then be written directly from Linux.
require_relative '../lib/rubycam'
require 'fiddle'

UVCIOC_CTRL_QUERY = Rubycam::Ioctl.iowr('u', 0x21, 16)
QUERY = { cur: 0x81, len: 0x85, info: 0x86 }.freeze
UNIT = 2
SELECTORS = [*0x01..0x10, 0x13].freeze

def query(io, unit, selector, code, size)
  buf = Fiddle::Pointer.malloc(size, Fiddle::RUBY_FREE)
  io.ioctl(UVCIOC_CTRL_QUERY, [unit, selector, code, size, buf.to_i].pack('C3xvx2Q'))
  buf[0, size].bytes
rescue SystemCallError => e
  e
end

def info_flags(bytes)
  return '-' unless bytes.is_a?(Array)

  v = bytes[0]
  %i[GET SET DISABLED AUTOUPDATE ASYNC]
    .each_index.select { |i| v[i] == 1 }
    .map { |i| %i[GET SET DISABLED AUTOUPDATE ASYNC][i] }.join('|')
end

dev = Rubycam::Device.find('OBSBOT Tiny 2') or abort 'xu_probe: no camera found'
io = dev.to_io
out = ARGV[0] ? File.open(ARGV[0], 'w') : $stdout

out.puts "# OBSBOT Tiny 2 extension-unit dump (unit #{UNIT})"
out.puts format('# %-4s %-18s %-4s %s', 'sel', 'info', 'len', 'GET_CUR (60 bytes hex)')
SELECTORS.each do |sel|
  len = query(io, UNIT, sel, QUERY[:len], 2)
  wlen = len.is_a?(Array) ? len[0] | (len[1] << 8) : 0
  cur = wlen.positive? ? query(io, UNIT, sel, QUERY[:cur], wlen) : nil
  hex = cur.is_a?(Array) ? cur.map { |b| format('%02x', b) }.join : cur.to_s
  info = info_flags(query(io, UNIT, sel, QUERY[:info], 1))
  out.puts format('0x%02x %-18s %-4s %s', sel, info, wlen, hex)
end

out.close unless out == $stdout
dev.close
warn "wrote #{ARGV[0]}" if ARGV[0]
