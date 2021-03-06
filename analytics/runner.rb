#!/usr/bin/env ruby

require "cgi"
require "date"
require "open3"
require "set"
require "uri"

require "toml-rb"


def get_docker_logs(container_name, days)
  stdout, _, _ = Open3.capture3(
    "docker", "logs", "--since", "#{days * 24 * 60}m", container_name)
  stdout.split(/\n/)
end


REJECTIONS = TomlRB.load_file("rejections.toml")
  .map { |k, v| [k, Set.new(v)] }
  .to_h

REFERRERS = TomlRB.load_file("referrers.toml")

NGINX_LOG_REGEX = %r{
    ^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s-\s-\s
    \[(?<date>\d{2}\/[A-Z][a-z]{2}\/\d{4}:\d{2}:\d{2}:\d{2}\s(\+|\-)\d{4})\]\s
    "(?:OPTIONS|HEAD|GET|POST)\s(?<url>.+)\sHTTP\/1\.[01]"\s
    (?<status>\d{3})\s
    (?<bytes_sent>\d+)\s
    "(?:\-|[^"]*)"\s
    "(?<user_agent>[^"]*)"\s
    "(?<forwarded_host>[^"]+)"
}x


def should_be_rejected(hit)
  path = hit["url"].downcase
  user_agent = hit["user_agent"]
  (
    REJECTIONS["bad_paths"].include? path or
    REJECTIONS["bad_path_prefixes"].any? { |prefix| path.start_with? prefix } or
    REJECTIONS["bad_path_suffixes"].any? { |suffix| path.end_with? suffix } or
    REJECTIONS["bad_user_agents"].any? { |ua| user_agent.include? ua } or
    (
        path.include? "/alexwlchan" and
        [".rar", ".tar", ".tar.gz", ".tgz", ".zip"].any? { |s| path.end_with? s }
    )
  )
end


def parse_lines(lines)
  lines
    .select { |line| NGINX_LOG_REGEX.match(line) != nil }
    .map { |line| NGINX_LOG_REGEX.match(line).named_captures.to_h }
    .select { |h| ! should_be_rejected(h) }
    .each { |h|
      h["status"] = h["status"].to_i
      h["date"] = DateTime.strptime(h["date"], "%d/%b/%Y:%H:%M:%S %z")
    }
end


def get_tracking_data(parsed_lines)
  parsed_lines
    .each { |line|
      if line.fetch("url", "").start_with?("/analytics/a.gif")
        query_str = line["url"][17..-1]
        parsed_qs = CGI::parse(query_str)
        line["title"] = parsed_qs["t"][0]
        line["referrer"] = parsed_qs["ref"][0]
        line["url"] = parsed_qs["url"][0]
      end
    }
end


def get_interesting_hits
  lines = get_docker_logs("infra_alexwlchan_1", 7)
  parsed_lines = parse_lines(lines)
  get_tracking_data(parsed_lines)
end


def normalise_referrers(hits)
  hits
    .each { |hit|
      if hit["referrer"] != nil
        normalise_referrer(hit)
      end
    }
    .select { |hit|
      # Discard spam
      hit["referrer"] == nil || !hit.fetch("referrer", "").start_with?("https://www.ecblog.xyz") }
end


GENERIC_SEARCHES = REFERRERS["search"]["urls"].to_set

def is_generic_search_referrer(ref)
  /^https?:\/\/www\.google\.[a-z]+(?:\.[a-z]+)?\/?$/.match(ref) != nil ||
  GENERIC_SEARCHES.include?(ref) || ref.start_with?(
    "https://yandex.ru/",
    "https://r.search.yahoo.com/",
    "https://search.myway.com/search",
    "http://int.search.myway.com/search",
    "https://r.search.aol.com/",
  )
end


def is_search_traffic(ref)
  is_generic_search_referrer(ref)
end


def extract_query_param(url, query_key)
  if URI.parse(url).query == nil
    ""
  else
    CGI::parse(URI.parse(url).query)[query_key][0]
  end
end


def normalise_referrer(hit)
  ref = hit["referrer"]
  is_search = false

  hit["referrer"] = if ref == "" || ref == nil || ref.start_with?("https://alexwlchan.net") || ref == "https://www.vpnbook.com/webproxy" || ref == "https://inbrowserapp.com/redirect"
    nil
  elsif is_generic_search_referrer(ref)
    is_search = true
    "[Unknown search term]"
  elsif ref.start_with?(
    "https://www.google.",
    "http://www.google.",
    "https://www.bing.com/search",
    "https://www4.bing.com/search",
    "http://www.bing.com/search",
    "https://cn.bing.com/search",
    "https://cse.google.com/cse",
    "https://www.ecosia.org/search",
    "https://bitmotion-tab.com/search",
    "https://search.lilo.org/",
    "https://www.searchpage.com/do/search",
  )
    is_search = true
    result = extract_query_param(ref, "q")
    if result == ""
      "[Unknown search term]"
    else
      result
    end
  elsif ref.start_with?("https://finduntaggedtumblrposts.com/results/")
    "https://finduntaggedtumblrposts.com/"
  elsif ref.start_with?("https://getpocket.com/redirect")
    ref.split("&h=")[0]
  elsif ref.start_with?("https://t.co")
    matching_referrers = REFERRERS["twitter"]
      .select { |k, v| ref.start_with?(k) }
      .values
    if matching_referrers.length == 1
      matching_referrers[0]
    else
      ref
    end

  # This is some sort of captcha/intermediary page that somebody sees,
  # but doesn't tell me where they originally came from.  Ditch it
  # from the logs.
  elsif ref.start_with?("https://captcha.gecirtnotification.com/pitc/")
    nil
  else
    REFERRERS["aliases"].fetch(ref, ref)
  end

  hit["referrer_is_search"] = is_search
end


def _tally_results(hits, key)
  result = Hash.new

  hits
    .each { |hit|
      if result[hit[key]] == nil
        result[hit[key]] = {
          "count" => 0,
          "latest" => nil
        }
      end

      result[hit[key]]["count"] += 1

      if result[hit[key]]["latest"] == nil
        result[hit[key]]["latest"] = hit["date"]
      else
        new_date = [
          hit["date"], result[hit[key]]["latest"]
        ].max
        result[hit[key]]["latest"] = new_date
      end
    }

  result
end


def summarise_referrers(hits)
  _tally_results(
    hits
      .select { |hit| !hit["referrer_is_search"] && hit["referrer"] != nil },
    "referrer"
  )
end


def summarise_search_referrers(hits)
  _tally_results(
    hits.select { |hit| hit["referrer_is_search"] },
    "referrer"
  )
end


def summarise_pages(hits)
  _tally_results(
    hits
      .select { |hit| hit["title"] != nil }
      .each { |hit| hit["title"] = hit["title"].gsub(/ – alexwlchan$/, "")},
    "title"
  )
end


def summarise_errors(hits)
  _tally_results(
    hits
      .select { |hit| hit["status"] >= 400 && hit["status"] != 410 }
      .select { |hit|
        !hit["url"].end_with?(".php", "%20%20t") &&
        !hit["url"].start_with?("/experiments")
      }
      .each { |hit| hit["error_description"] = "#{hit["url"]} (#{hit["status"]})" },
    "error_description"
  )
end


def print_title(title)
  puts ""
  puts "=" * (title.length + 2)
  puts " #{title} "
  puts "=" * (title.length + 2)
end


def print_tally(title, tally, limit)
  print_title(title)

  result = tally
    .sort_by { |k, v| [v["count"], v["latest"]] }
    .reverse
    .map { |k, v| [k, v["count"]] }[0..(limit - 1)]
    .to_h

  bar_width = 4.0
  max_value = result.values.max
  increment = max_value / bar_width

  result
    .each { |k, total|
      # The ASCII block elements come in chunks of 8, so we work out how
      # many fractions of 8 we need.
      # https://en.wikipedia.org/wiki/Block_Elements
      bar_chunks, remainder = (total * 8 / increment).divmod(8)

      bar = "█" * bar_chunks

      # Then add the fractional part.  The Unicode code points for
      # block elements are (8/8), (7/8), (6/8), ... , so we need to
      # work backwards.
      if remainder.floor > 0
        bar += ("█".ord + (8 - remainder.floor)).chr(Encoding::UTF_8)
      end

      if bar == ""
        bar = '▏'
      end

      puts "#{total.to_s.rjust(5)} #{bar.ljust(bar_width + 1)} #{k}"
    }
end


hits = normalise_referrers(get_interesting_hits())

print_title("Headline numbers")
unique_hosts = hits.map { |hit| hit["forwarded_host"] }.to_set
puts "#{hits.length.to_s.rjust(5)} hits"
puts "#{unique_hosts.length.to_s.rjust(5)} unique IP addresses"

print_tally("Search terms", summarise_search_referrers(hits), 10)
print_tally("Referrer URLs", summarise_referrers(hits), 50)
print_tally("Popular pages", summarise_pages(hits), 10)
print_tally("Errors", summarise_errors(hits), 10)
