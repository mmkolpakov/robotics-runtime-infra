{
  resourceMetrics: [
    {
      resource: {
        attributes: [
          {
            key: "service.name",
            value: {stringValue: "robotics-foundation-probe"}
          }
        ]
      },
      scopeMetrics: [
        {
          scope: {
            name: "robotics.runtime.foundation",
            version: "1"
          },
          metrics: [
            {
              name: "robotics.time_authority.offset",
              unit: "ms",
              gauge: {
                dataPoints: [
                  range(0; 30) as $sample
                  | {
                      attributes: [
                        {
                          key: "time.source.id",
                          value: {stringValue: $source_id}
                        }
                      ],
                      asDouble: 0,
                      timeUnixNano: $timestamp
                    }
                ]
              }
            },
            {
              name: "robotics.message.age",
              unit: "ms",
              gauge: {
                dataPoints: [
                  {
                    attributes: [
                      {
                        key: "channel",
                        value: {stringValue: "/clock"}
                      }
                    ],
                    asDouble: 1,
                    timeUnixNano: $timestamp
                  }
                ]
              }
            },
            {
              name: "robotics.message.loss_ratio",
              unit: "1",
              gauge: {
                dataPoints: [
                  {
                    attributes: [
                      {
                        key: "channel",
                        value: {stringValue: "/clock"}
                      }
                    ],
                    asDouble: 0,
                    timeUnixNano: $timestamp
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
