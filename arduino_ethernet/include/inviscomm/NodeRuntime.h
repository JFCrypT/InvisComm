#pragma once
#include <Arduino.h>
#include "inviscomm/InvisCommEngine.h"
#include "transports/EthernetUdpTransport.h"

class NodeRuntime {
public:
    NodeRuntime(const char* name,uint8_t nodeId,uint8_t peerId,const char* direction,
                const char* startupMessage,EthernetUdpTransport& transport);
    void beginAfterStart(uint32_t startAtMs);
    void tick();
    bool halted() const { return halted_; }
private:
    const char* name_; uint8_t nodeId_; uint8_t peerId_; const char* direction_; const char* message_;
    uint8_t messageIndex_; uint32_t txPos_; uint32_t rxPos_; uint32_t nextTxMs_; uint32_t telSeq_;
    uint32_t noiseState_; bool started_; bool halted_;
    EthernetUdpTransport& transport_;
    InvisCommEngine txEngine_; InvisCommEngine rxEngine_;
    char nextChar(bool& isInfo);
    uint32_t nextNoise();
    void transmitOne();
    void receiveAvailable();
    void fail(const __FlashStringHelper* reason,uint32_t got,uint32_t expected);
};
