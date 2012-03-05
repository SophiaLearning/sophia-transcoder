require "rubygems"
require "aws-sdk"
require "streamio-ffmpeg"
require "active_support/all"
require 'logger'
require 'ostruct'
require 'tmpdir'

module Transcoder

  def use_ffmpeg?
    ENV['TRANSCODE'] == 'ffmpeg'
  end

  def guaranteach?
    ENV['TARGET'] == 'gt'
  end

  def transcode_with_zencoder(id, input_url, label, callback_url=nil)
    base_url = proc { |quality| "s3://#{sophia_config.s3_bucket}/zencoder_asset/#{sophia_config.appid}/#{id}/#{quality}"}
    label = proc {|quality| "sophia-#{quality}" }

    recipe = {
      :api_key  => sophia_config.zencoder_api_key,
      :input    => input_url,
      :output   => [{
        "base_url"         => base_url['900'],
        :notifications     => callback_url,
        :label             => label['900'],
        :width             => 700,
        :video_codec       => "h264",
        :quality           => 5,
        :video_bitrate     => 900,
        :thumbnails        => {
          :base_url => base_url['900'],
          :number   => 1,
          :size     => "700x400"
        }
      },
      {"base_url"          => base_url['700'],
        :notifications     => callback_url,
        :label             => label['700'],
        :width             => 700,
        :video_codec       => "h264",
        :quality           => 5,
        :video_bitrate     => 700,
        :thumbnails        => {
          :base_url => base_url['700'],
          :number   => 1,
          :size     => "700x400"
        }
      },
      {"base_url"          => base_url['200'],
        :notifications     => callback_url,
        :label             => label['200'],
        :width             => 700,
        :video_codec       => "h264",
        :quality           => 5,
        :video_bitrate     => 200,
        :thumbnails        => {
          :base_url => base_url['200'],
          :number   => 1,
          :size     => "700x400"
        }
      }

     ]
    }
    # Explicitly set the test parameter. ZenCoder failed by changing treatment of the param where the existence of the param made test true.
    recipe.merge!(:test => 1) if sophia_config.zencoder_testing == true
    logger.info "ZENCODER RECIPE:\n#{recipe.inspect}\n"
    data = Zencoder::Job.create(recipe)
    logger.info "ZENCODER RESPONSE:\n#{data.body.inspect}\n"
    [data.body, recipe]
  end

  # you might need non-trivial ffmpeg installing: http://ubuntuforums.org/showthread.php?t=786095
  def transcode_with_ffmpeg(id, input_url)
    movie = nil
    Dir.mktmpdir("sophia-transcode-#{id}") do |dir|
      bucket = sophia_config.s3_bucket
      key    = "/ffmpeg_asset/#{sophia_config.appid}/#{id}"
      to_key = proc { |k, ext| "#{key}/#{k}.#{ext}" }
      to_path= proc { |fn| File.join(dir, fn) }

      input_path  = to_path['input']
      download_s3(input_url, input_path)
      movie = FFMPEG::Movie.new(input_path)
      movie.valid? or raise "Invalid movie"

      # encode video in 200k, 600k, 900k bitrate
      #[ [200, 35], [600, 31], [900, 24] ] to support multiple resolutions
      bitrates  = [ [200, 35], [900, 24] ]
      keys = bitrates.map { |b,k| to_key[b, 'mp4'] }

      # upload original file
      @last_original = to_key['original', 'mp4']
      upload_s3(bucket, @last_original, input_path) if guaranteach?

      # transcode and upload to s3
      bitrates.each do |bitrate, quality|
        output = to_path["#{bitrate}.mp4"]
        transcode_video(movie, output, bitrate, quality)
        upload_s3(bucket, to_key[bitrate, 'mp4'], output)
      end

      # encode thumbnail
      thumb_path = to_path['thumb.png']
      thumb_key  = to_key['thumbnail', 'png']

      transcode_thumbnail(movie, thumb_path)
      upload_s3(bucket, thumb_key, thumb_path)

      return [keys, thumb_key]
    end

#  rescue => e
#    logger.info "invalid movie: #{movie.inspect}" if movie
#    logger.info "#{e.inspect}\n#{e.backtrace.join}" if e
#    nil
  end

  # private

  def _d f, p
    FileUtils.cp f, p
  end

  def transcode_video(input_movie, output_video, bitrate, quality, expected_width = 700)
    resolution  = new_size(input_movie, expected_width).try { |r| "-s %dx%d" % r }
    compression = " -qmin #{quality}" if input_movie.video_bitrate.try :>, bitrate
    input_bt = input_movie.audio_bitrate.to_i
    audio_bitrate =  input_bt >= 96 ? input_bt : 96

    input_movie.transcode(
      output_video,
      " -vcodec libx264 -b:v #{bitrate}k #{resolution} #{compression} " +
      " -vpre libx264-medium -threads 0 " +
      " -acodec aac -b:a #{audio_bitrate}k -ar 44100 -strict -2")
  end

  def new_size(input_movie, expected_width)
    if input_movie.width.try :>, expected_width
      [expected_width, round2(input_movie.height * expected_width / input_movie.width.to_f)]
    end
  end

  def transcode_thumbnail(input_movie, output_thumbnail, resolution = '700x400', time_ratio = 0)
    resolution =~ /\d{1,4}x\d{1,4}/ or raise "invalid resolution format: #{resolution}"
    start_time = input_movie.duration.*(time_ratio).to_i

    input_movie.transcode(
      output_thumbnail,
      "-s #{resolution} -ss #{start_time} -vframes 1 -vcodec png -pix_fmt rgb24")
  end

  def download(url, file_name)
    File.open(file_name, 'wb') { |out|
      Net::HTTP.get_response(URI.parse(url)) { |r|
        r.read_body(&out.method(:write))
      }
    }
  end

  def download_s3(url, file_name)
    bucket, key = url.is_a?(Array) ? url : parse_s3(url)

    bucket    = AWS::S3::Bucket.new(bucket)
    s3_object = AWS::S3::S3Object.new(bucket, key)

    logger.info "...downloading file from #{s3_object.url_for(:get)}"

    File.open(file_name, 'wb') do |f|
      f.puts s3_object.read
    end
    logger.info "...downloaded!"
  end

  def upload_s3(bucket, key, file_name)
    bucket = AWS::S3.new.buckets[bucket]
    object = bucket.objects[key[1..-1]]

    logger.info "...uploading file to #{object.url_for(:get)}"

    object.write(File.read(file_name))

    logger.info "...uploaded!"
  end

  def parse_s3(url)
    if sophia_config.s3_host_alias && !guaranteach?
      match, bucket, key = *url.match('^http://([^\/]+).s3.amazonaws.com/(.*)$')
    else
      match, bucket, key = *url.match('^http://s3.amazonaws.com/([^\/]+)/(.*)$')
    end

    match or raise "invalid AWS S3 URL: #{url}"
    [bucket, key]
  end

  # video height for x264 must be divisible by 2
  def round2(x)
    x./(2).round * 2
  end

  def logger
    @logger ||= Logger.new 'transcoder'
  end

  def sophia_config
    @config ||= Sophia::CONFIG
  end

  def sophia_config=(value)
    @config = value
  end

  # ugly backdoor to get last original file from s3
  def last_original
    @last_original
  end

  extend self
end
