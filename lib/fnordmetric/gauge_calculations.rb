module FnordMetric::GaugeCalculations

  @@avg_per_session_proc = proc{ |_v, _t|
    (_v.to_f / (redis.get(tick_key(_t, :"sessions-count"))||1).to_i)
  }

  @@count_per_session_proc = proc{ |_v, _t|
    (redis.get(tick_key(_t, :"sessions-count"))||0).to_i
  }

  @@avg_per_count_proc = proc{ |_v, _t|
    (_v.to_f / (redis.get(tick_key(_t, :"value-count"))||1).to_i)
  }

  @@median_per_count_proc = proc { |_v, _t|
    res = (redis.get(tick_key(_t, :"value-count"))||[1]).sort
    res[res.size / 2]
  }

  def value_at(time, opts={}, &block)
    _t = tick_at(time)
    _v = redis.hget(key, _t)

    calculate_value(_v, _t, opts, block)
  end

  def values_at(times, opts={}, &block)
    times = times.map{ |_t| tick_at(_t) }
    Hash.new.tap do |ret|
      redis.hmget(key, *times).each_with_index do |_v, _n|
        _t = times[_n]
        ret[_t] = calculate_value(_v, _t, opts, block)
      end
    end
  end

  def values_in(range, opts={}, &block)
    values_at((tick_at(range.first)..range.last).step(tick))
  end

  def calculate_value(_v, _t, opts, block)
    block = @@avg_per_count_proc if average?
    #block = @@count_per_session_proc if unique?
    block = @@avg_per_session_proc if unique? && average?
    block = @@median_per_count_proc if median?

    if block
      instance_exec(_v, _t, &block)
    else
      _v
    end
  end

  def field_values_at(time, opts={}, &block)
    opts[:max_fields] ||= @opts[:max_fields] ||= 25
    opts[:discard_others] ||= @opts[:discard_others] ||= false

    all_values = redis.zrevrange(tick_key(time), 0, -1, :withscores => true)

    unless Redis::VERSION =~ /^3.0/
      all_values = all_values.in_groups_of(2)
    end
    rv = []

    # if all fields are requested
    opts[:max_fields] = all_values.size if opts[:max_fields] == 0
    # show the top list as individuals, and wrap the rest as 'others'.
    indiv_end = opts[:max_fields] - 1

    all_values[0..indiv_end].each do |key, val|
      rv << [key, calculate_value(val, time, opts, block)]
    end

    unless opts[:discard_others] || all_values.size <= opts[:max_fields]
      # now wrap the 'others'
      finish = all_values.size
      start  = opts[:max_fields]

      total_other = all_values[start..finish].each.map(&:last).map(&:to_i).sum
      rv << ['Others', calculate_value(total_other, time, opts, block)]
    end

    return rv
  end

  def field_values_total(time)
    (redis.get(tick_key(time, :count))||0).to_i
  end

  def redis
    @opts[:redis]
  end

end
