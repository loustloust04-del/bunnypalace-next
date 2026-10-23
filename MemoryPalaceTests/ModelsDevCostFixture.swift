import Foundation

// 2026-10-11 curl https://models.dev/api.json：保留真实 cost 形状与值。
// tiers: [{ input, output, cache_read?, tier: { type: "context", size: Int } }]
// context_over_200k 是兼容字段；有具体 tiers 时按实际 size，不能一律用 200k。
enum ModelsDevCostFixture {
    static let data = Data(#"""
{
  "google": {
    "id": "google",
    "models": {
      "gemini-2.5-pro": {
        "id": "gemini-2.5-pro",
        "name": "Gemini 2.5 Pro",
        "cost": {
          "input": 1.25,
          "output": 10,
          "cache_read": 0.125,
          "tiers": [
            {
              "input": 2.5,
              "output": 15,
              "cache_read": 0.25,
              "tier": {
                "type": "context",
                "size": 200000
              }
            }
          ],
          "context_over_200k": {
            "input": 2.5,
            "output": 15,
            "cache_read": 0.25
          }
        },
        "limit": {
          "context": 1048576,
          "output": 65536
        }
      }
    }
  },
  "deepinfra": {
    "id": "deepinfra",
    "models": {
      "Qwen/Qwen3-Max": {
        "id": "Qwen/Qwen3-Max",
        "name": "Qwen3 Max",
        "cost": {
          "input": 1.2,
          "output": 6,
          "cache_read": 0.24,
          "tiers": [
            {
              "input": 2.4,
              "output": 12,
              "cache_read": 0.48,
              "tier": {
                "type": "context",
                "size": 32000
              }
            },
            {
              "input": 3,
              "output": 15,
              "cache_read": 0.6,
              "tier": {
                "type": "context",
                "size": 128000
              }
            }
          ]
        },
        "limit": {
          "context": 256000,
          "output": 65536
        }
      }
    }
  },
  "anthropic": {
    "id": "anthropic",
    "models": {
      "claude-opus-4-6": {
        "id": "claude-opus-4-6",
        "name": "Claude Opus 4.6",
        "cost": {
          "input": 5,
          "output": 25,
          "cache_read": 0.5,
          "cache_write": 6.25
        },
        "limit": {
          "context": 1000000,
          "output": 128000
        }
      }
    }
  },
  "openai": {
    "id": "openai",
    "models": {
      "gpt-6.1-sol": {
        "id": "gpt-6.1-sol",
        "name": "GPT-6.1 Sol",
        "cost": {
          "input": 2,
          "output": 10,
          "cache_read": 0.1,
          "cache_write": 2.5,
          "tiers": [
            {
              "input": 4,
              "output": 15,
              "cache_read": 0.2,
              "cache_write": 5,
              "tier": {
                "type": "context",
                "size": 272000
              }
            }
          ],
          "context_over_200k": {
            "input": 4,
            "output": 15,
            "cache_read": 0.2,
            "cache_write": 5
          }
        },
        "limit": {
          "context": 1050000,
          "input": 922000,
          "output": 128000
        }
      }
    }
  }
}
"""#.utf8)
}
