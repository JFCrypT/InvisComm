#include "inviscomm/NodeRuntime.h"
#include "inviscomm/Config.h"
#include "inviscomm/Frame.h"

NodeRuntime::NodeRuntime(const char* name,uint8_t nodeId,uint8_t peerId,const char* direction,
                         const char* startupMessage,EthernetUdpTransport& transport)
: name_(name),nodeId_(nodeId),peerId_(peerId),direction_(direction),message_(startupMessage),messageIndex_(0),
  txPos_(0),rxPos_(0),nextTxMs_(0),telSeq_(0),noiseState_(InvisCommConfig::SHARED_KEY ^ ((uint32_t)nodeId*0x9E3779B9UL)),
  started_(false),halted_(false),transport_(transport),
  txEngine_(InvisCommConfig::SHARED_KEY,InvisCommConfig::ALPHABET,InvisCommConfig::ALPHABET_LEN),
  rxEngine_(InvisCommConfig::SHARED_KEY,InvisCommConfig::ALPHABET,InvisCommConfig::ALPHABET_LEN) {}

void NodeRuntime::beginAfterStart(uint32_t startAtMs){ nextTxMs_=startAtMs; started_=true; }
uint32_t NodeRuntime::nextNoise(){ uint32_t x=noiseState_; x^=x<<13; x^=x>>17; x^=x<<5; noiseState_=x?x:0xA5A5A5A5UL; return noiseState_; }
char NodeRuntime::nextChar(bool& isInfo){
    const char c=message_[messageIndex_];
    if(c!='\0'){ isInfo=true; messageIndex_++; return c; }
    isInfo=false; return InvisCommConfig::ALPHABET[nextNoise()%InvisCommConfig::ALPHABET_LEN];
}

void NodeRuntime::transmitOne(){
    bool info=false; const char c=nextChar(info); uint16_t coord=0;
    const uint32_t t0=micros();
    if(!txEngine_.encodeSymbol(c,txPos_,coord)){ fail(F("encode"),txPos_,txPos_); return; }
    const uint32_t encodeUs=micros()-t0;
    uint8_t frame[InvisFrame::SIZE]; InvisFrame::encode(nodeId_,0,txPos_,coord,frame);
    const uint32_t s0=micros(); const bool ok=transport_.send(frame,sizeof(frame)); const uint32_t sendUs=micros()-s0;
    if(!ok){ Serial.print(F("LOG,")); Serial.print(name_); Serial.println(F(",ERROR,UDP send failed")); halted_=true; return; }
    Serial.print(F("TEL,")); Serial.print(telSeq_++); Serial.print(','); Serial.print(millis()/1000.0,3); Serial.print(',');
    Serial.print(direction_); Serial.print(','); Serial.print(coord); Serial.print(','); Serial.print(info?F("Info"):F("Noise")); Serial.print(','); Serial.println(name_);
    Serial.print(F("PERF,")); Serial.print(name_); Serial.print(F(",EthernetUDP,")); Serial.print(txPos_); Serial.print(','); Serial.print(encodeUs); Serial.print(','); Serial.println(sendUs);
    txPos_++;
}

void NodeRuntime::fail(const __FlashStringHelper* reason,uint32_t got,uint32_t expected){
    Serial.print(F("LOG,")); Serial.print(name_); Serial.print(F(",ERROR,")); Serial.print(reason); Serial.print(F(": recibida=")); Serial.print(got); Serial.print(F(", esperada=")); Serial.println(expected); halted_=true;
}

void NodeRuntime::receiveAvailable(){
    uint8_t frame[InvisFrame::SIZE];
    for(uint8_t n=0;n<4;n++){
        const int len=transport_.receive(frame,sizeof(frame)); if(len==0) return; if(len<0) continue;
        uint8_t sender,flags; uint32_t pos; uint16_t coord;
        if(!InvisFrame::decode(frame,sender,flags,pos,coord)){ Serial.print(F("LOG,")); Serial.print(name_); Serial.println(F(",ERROR,invalid frame")); halted_=true; return; }
        if(sender!=peerId_) continue;
        if(pos!=rxPos_){ fail(F("Pérdida o desorden"),pos,rxPos_); return; }
        char c='?'; const uint32_t d0=micros(); if(!rxEngine_.decodeCoordinate(coord,rxPos_,c)){ fail(F("decode"),pos,rxPos_); return; } const uint32_t decodeUs=micros()-d0;
        Serial.print(F("RX,")); Serial.print(name_); Serial.print(','); Serial.print(pos); Serial.print(','); Serial.print(coord); Serial.print(F(",'")); Serial.print(c); Serial.print(F("',")); Serial.println(decodeUs);
        rxPos_++;
    }
}

void NodeRuntime::tick(){
    if(!started_||halted_) return;
    receiveAvailable(); if(halted_) return;
    const uint32_t now=millis();
    if((int32_t)(now-nextTxMs_)>=0){ transmitOne(); nextTxMs_+=InvisCommConfig::TX_INTERVAL_MS; }
}
