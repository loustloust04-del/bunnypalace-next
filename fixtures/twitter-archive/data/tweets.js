window.YTD.tweets.part0 = [
  {
    "tweet" : {
      "id_str" : "1000000000000000001",
      "full_text" : "第一条推文 a=b&c=d #测试 @someone https://t.co/abc",
      "created_at" : "Wed Oct 10 20:19:24 +0000 2018",
      "favorite_count" : "12",
      "retweet_count" : "3",
      "entities" : {
        "hashtags" : [ { "text" : "测试" } ],
        "user_mentions" : [ { "screen_name" : "someone" } ],
        "urls" : [ { "expanded_url" : "https://example.com/post" } ]
      }
    }
  },
  {
    "tweet" : {
      "id_str" : "1000000000000000002",
      "full_text" : "回复别人的推文",
      "created_at" : "Thu Oct 11 08:00:00 +0000 2018",
      "favorite_count" : "0",
      "retweet_count" : "0",
      "in_reply_to_status_id_str" : "1000000000000000001",
      "in_reply_to_screen_name" : "susu_test",
      "entities" : { "hashtags" : [], "user_mentions" : [], "urls" : [] }
    }
  }
]
