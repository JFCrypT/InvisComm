#include "inviscomm/Frame.h"

namespace InvisFrame {
uint16_t crc16CcittFalse(const uint8_t* data,size_t len){
    uint16_t crc=0xFFFF;
    for(size_t i=0;i<len;i++){
        crc^=(uint16_t)data[i]<<8;
        for(uint8_t b=0;b<8;b++) crc=(crc&0x8000)?(uint16_t)((crc<<1)^0x1021):(uint16_t)(crc<<1);
    }
    return crc;
}
void encode(uint8_t sender,uint8_t flags,uint32_t position,uint16_t coordinate,uint8_t out[SIZE]){
    out[0]=MAGIC; out[1]=VERSION; out[2]=sender; out[3]=flags;
    out[4]=(uint8_t)(position>>24); out[5]=(uint8_t)(position>>16); out[6]=(uint8_t)(position>>8); out[7]=(uint8_t)position;
    out[8]=(uint8_t)(coordinate>>8); out[9]=(uint8_t)coordinate;
    const uint16_t crc=crc16CcittFalse(out,10); out[10]=(uint8_t)(crc>>8); out[11]=(uint8_t)crc;
}
bool decode(const uint8_t in[SIZE],uint8_t& sender,uint8_t& flags,uint32_t& position,uint16_t& coordinate){
    if(in[0]!=MAGIC||in[1]!=VERSION) return false;
    const uint16_t expected=((uint16_t)in[10]<<8)|in[11]; if(crc16CcittFalse(in,10)!=expected) return false;
    sender=in[2]; flags=in[3];
    position=((uint32_t)in[4]<<24)|((uint32_t)in[5]<<16)|((uint32_t)in[6]<<8)|in[7];
    coordinate=((uint16_t)in[8]<<8)|in[9]; return coordinate<=1023;
}
}
