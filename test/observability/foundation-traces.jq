{
  resourceSpans: [
    {
      resource: {
        attributes: [
          {
            key: "service.name",
            value: {stringValue: "robotics-foundation-probe"}
          }
        ]
      },
      scopeSpans: [
        {
          scope: {
            name: "robotics.runtime.foundation",
            version: "1"
          },
          spans: [
            {
              traceId: "0123456789abcdef0123456789abcdef",
              spanId: "0123456789abcdef",
              name: "foundation observation",
              kind: 1,
              startTimeUnixNano: $start_timestamp,
              endTimeUnixNano: $end_timestamp,
              attributes: [
                {
                  key: "messaging.message.id",
                  value: {stringValue: "foundation-message-1"}
                },
                {
                  key: "robotics.channel.id",
                  value: {stringValue: "foundation.clock"}
                }
              ],
              droppedAttributesCount: 0,
              droppedEventsCount: 0,
              droppedLinksCount: 0
            }
          ]
        }
      ]
    }
  ]
}
