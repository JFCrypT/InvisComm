#include <Arduino.h>
#include <SPI.h>
#include <Ethernet.h>
#include "inviscomm/Config.h"
#include "inviscomm/Frame.h"
#include "inviscomm/NodeRuntime.h"
#include "transports/EthernetUdpTransport.h"

#if defined(NODE_ROLE_ALICE)
static const char NODE_NAME[]="Alice";
static const char DIRECTION[]="A-->B";
static const uint8_t NODE_ID=InvisFrame::NODE_A;
static const uint8_t PEER_ID=InvisFrame::NODE_B;
static const uint16_t LOCAL_PORT=InvisCommConfig::UDP_PORT_ALICE;
static const uint16_t REMOTE_PORT=InvisCommConfig::UDP_PORT_BOB;
static const char* MESSAGE=InvisCommConfig::MESSAGE_ALICE;
static const uint8_t MAC_ADDR[6]={0x02,0x49,0x4E,0x56,0x41,0x01};
#elif defined(NODE_ROLE_BOB)
static const char NODE_NAME[]="Bob";
static const char DIRECTION[]="B-->A";
static const uint8_t NODE_ID=InvisFrame::NODE_B;
static const uint8_t PEER_ID=InvisFrame::NODE_A;
static const uint16_t LOCAL_PORT=InvisCommConfig::UDP_PORT_BOB;
static const uint16_t REMOTE_PORT=InvisCommConfig::UDP_PORT_ALICE;
static const char* MESSAGE=InvisCommConfig::MESSAGE_BOB;
static const uint8_t MAC_ADDR[6]={0x02,0x49,0x4E,0x56,0x42,0x02};
#else
#error Define NODE_ROLE_ALICE or NODE_ROLE_BOB
#endif

EthernetUdpTransport transport(LOCAL_PORT,REMOTE_PORT);
NodeRuntime runtime(NODE_NAME,NODE_ID,PEER_ID,DIRECTION,MESSAGE,transport);
bool waitingStart=true;

void printIp(const IPAddress& ip){ Serial.print(ip[0]); Serial.print('.'); Serial.print(ip[1]); Serial.print('.'); Serial.print(ip[2]); Serial.print('.'); Serial.println(ip[3]); }

void setup(){
    Serial.begin(115200);
    while(!Serial && millis()<2000){}
    delay(500);
    Serial.println(); Serial.println(F("========================================")); Serial.println(F("InvisComm Arduino UNO Ethernet")); Serial.println(F("========================================"));
    Serial.print(F("Nodo: ")); Serial.println(NODE_NAME); Serial.println(F("Transporte: UDP/Ethernet")); Serial.println(F("Inicializando Ethernet por DHCP..."));
    if(!transport.begin(MAC_ADDR)){ Serial.print(F("LOG,")); Serial.print(NODE_NAME); Serial.println(F(",ERROR,Ethernet/DHCP initialization failed")); while(true){delay(1000);} }
    Serial.print(F("Ethernet conectado - IP: ")); printIp(transport.localIP());
    Serial.print(F("READY,")); Serial.print(NODE_NAME); Serial.print(F(",USB,")); Serial.println(millis());
}

void loop(){
    if(waitingStart){
        if(Serial.available()){
            char line[80]; const size_t n=Serial.readBytesUntil('\n',line,sizeof(line)-1); line[n]='\0';
            while(n>0 && (line[n-1]=='\r'||line[n-1]=='\n')) line[n-1]='\0';
            if(strncmp(line,"INVISCOMM_START,",16)==0){
                char* last=strrchr(line,','); uint16_t delayMs=InvisCommConfig::START_DELAY_MS; if(last) delayMs=(uint16_t)atoi(last+1);
                Serial.print(F("CONTROL,")); Serial.print(NODE_NAME); Serial.print(','); Serial.println(line+16);
                const uint32_t startAt=millis()+delayMs; runtime.beginAfterStart(startAt); waitingStart=false;
                Serial.print(F("START,")); Serial.println(NODE_NAME);
            }
        }
        return;
    }
    runtime.tick();
}
