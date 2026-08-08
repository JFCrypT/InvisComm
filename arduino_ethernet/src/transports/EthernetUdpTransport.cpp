#include "transports/EthernetUdpTransport.h"
#include "inviscomm/Config.h"
#include <SPI.h>

EthernetUdpTransport::EthernetUdpTransport(uint16_t localPort,uint16_t remotePort)
: localPort_(localPort), remotePort_(remotePort) {}

bool EthernetUdpTransport::begin(const uint8_t mac[6]){
    pinMode(InvisCommConfig::SD_CS_PIN,OUTPUT); digitalWrite(InvisCommConfig::SD_CS_PIN,HIGH);
    Ethernet.init(InvisCommConfig::ETHERNET_CS_PIN);
    uint8_t mutableMac[6]; memcpy(mutableMac,mac,6);
    if(Ethernet.begin(mutableMac)==0) return false;
    delay(500);
    return udp_.begin(localPort_)==1;
}

bool EthernetUdpTransport::send(const uint8_t* payload,uint8_t len){
    if(len!=InvisFrame::SIZE) return false;
    IPAddress broadcast(255,255,255,255);
    if(!udp_.beginPacket(broadcast,remotePort_)) return false;
    if(udp_.write(payload,len)!=len){ udp_.endPacket(); return false; }
    return udp_.endPacket()==1;
}

int EthernetUdpTransport::receive(uint8_t* payload,uint8_t maxLen){
    const int packetSize=udp_.parsePacket(); if(packetSize<=0) return 0;
    if(packetSize!=InvisFrame::SIZE){ while(udp_.available()) udp_.read(); return -1; }
    if(maxLen<InvisFrame::SIZE) return -1;
    return udp_.read(payload,InvisFrame::SIZE);
}
