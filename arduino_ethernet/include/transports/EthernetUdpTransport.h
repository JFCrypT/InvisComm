#pragma once
#include <Arduino.h>
#include <Ethernet.h>
#include <EthernetUdp.h>
#include "inviscomm/Frame.h"

class EthernetUdpTransport {
public:
    EthernetUdpTransport(uint16_t localPort,uint16_t remotePort);
    bool begin(const uint8_t mac[6]);
    bool send(const uint8_t* payload,uint8_t len);
    int receive(uint8_t* payload,uint8_t maxLen);
    IPAddress localIP() const { return Ethernet.localIP(); }
private:
    EthernetUDP udp_;
    uint16_t localPort_;
    uint16_t remotePort_;
};
