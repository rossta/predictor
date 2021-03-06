class Predictor::InputMatrix
  def initialize(opts)
    @opts = opts
  end

  def redis_key(*append)
    ([@opts.fetch(:redis_prefix), @opts.fetch(:key)] + append).flatten.compact.join(":")
  end

  def weight
    (@opts[:weight] || 1).to_f
  end

  def add_set(set_id, item_ids)
    Predictor.redis.multi do
      item_ids.each { |item| add_single_nomulti(set_id, item) }
    end
  end

  def add_set!(set_id, item_ids)
    add_set(set_id, item_ids)
    item_ids.each { |item_id| process_item!(item_id) }
  end

  def add_single(set_id, item_id)
    Predictor.redis.multi do
      add_single_nomulti(set_id, item_id)
    end
  end

  def add_single!(set_id, item_id)
    add_single(set_id, item_id)
    process_item!(item_id)
  end

  def all_items
    Predictor.redis.smembers(redis_key(:all_items))
  end

  def items_for(set)
    Predictor.redis.smembers redis_key(:items, set)
  end

  def sets_for(item)
    Predictor.redis.sunion redis_key(:sets, item)
  end

  def related_items(item_id)
    sets = Predictor.redis.smembers(redis_key(:sets, item_id))
    keys = sets.map { |set| redis_key(:items, set) }
    if keys.length > 0
      Predictor.redis.sunion(keys) - [item_id]
    else
      []
    end
  end

  def similarity(item1, item2)
    Predictor.redis.zscore(redis_key(:similarities, item1), item2)
  end

  # calculate all similarities to other items in the matrix for item1
  def similarities_for(item1, with_scores: false, offset: 0, limit: -1)
    Predictor.redis.zrevrange(redis_key(:similarities, item1), offset, limit == -1 ? limit : offset + (limit - 1), with_scores: with_scores)
  end

  def process_item!(item)
    cache_similarities_for(item)
  end

  def process!
    all_items.each do |item|
      process_item!(item)
    end
  end

  # delete item_id from the matrix
  def delete_item!(item_id)
    Predictor.redis.srem(redis_key(:all_items), item_id)
    Predictor.redis.watch(redis_key(:sets, item_id), redis_key(:similarities, item_id)) do
      sets = Predictor.redis.smembers(redis_key(:sets, item_id))
      items = Predictor.redis.zrange(redis_key(:similarities, item_id), 0, -1)
      Predictor.redis.multi do |multi|
        sets.each do |set|
          multi.srem(redis_key(:items, set), item_id)
        end

        items.each do |item|
          multi.zrem(redis_key(:similarities, item), item_id)
        end

        multi.del redis_key(:sets, item_id), redis_key(:similarities, item_id)
      end
    end
  end

  private

  def add_single_nomulti(set_id, item_id)
    Predictor.redis.sadd(redis_key(:all_items), item_id)
    Predictor.redis.sadd(redis_key(:items, set_id), item_id)
    # add the set_id to the item_id's set--inverting the sets
    Predictor.redis.sadd(redis_key(:sets, item_id), set_id)
  end

  def cache_similarity(item1, item2)
    score = calculate_jaccard(item1, item2)

    if score > 0
      Predictor.redis.multi do |multi|
        multi.zadd(redis_key(:similarities, item1), score, item2)
        multi.zadd(redis_key(:similarities, item2), score, item1)
      end
    end
  end

  def cache_similarities_for(item)
    related_items(item).each do |related_item|
      cache_similarity(item, related_item)
    end
  end

  def calculate_jaccard(item1, item2)
    x = nil
    y = nil
    Predictor.redis.multi do |multi|
      x = multi.sinterstore 'temp', [redis_key(:sets, item1), redis_key(:sets, item2)]
      y = multi.sunionstore 'temp', [redis_key(:sets, item1), redis_key(:sets, item2)]
      multi.del 'temp'
    end

    if y.value > 0
      return (x.value.to_f/y.value.to_f)
    else
      return 0.0
    end
  end
end