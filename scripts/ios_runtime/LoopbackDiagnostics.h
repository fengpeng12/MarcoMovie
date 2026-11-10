// Local probe diagnostics only. Does not replace the NSURLSession acceptance path.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

static NSDictionary *loopbackHealthDiagnostic(NSString *address) {
  NSURLComponents *url=[NSURLComponents componentsWithString:address];
  NSMutableDictionary *report=[@{@"connected":@NO,@"http_ok":@NO} mutableCopy];
  if (![url.scheme isEqual:@"http"] || ![url.host isEqual:@"127.0.0.1"] ||
      url.port.intValue<1 || url.port.intValue>65535) {
    report[@"error"]=@"invalid_loopback_address";return report;
  }
  int fd=socket(AF_INET,SOCK_STREAM,0);
  if(fd<0){report[@"errno"]=@(errno);return report;}
  int noSignal=1;
  setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
  fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0)|O_NONBLOCK);
  struct sockaddr_in peer={};peer.sin_family=AF_INET;peer.sin_port=htons(url.port.intValue);
  inet_pton(AF_INET,"127.0.0.1",&peer.sin_addr);
  NSTimeInterval deadline=NSDate.timeIntervalSinceReferenceDate+5;
  int connected=connect(fd,(struct sockaddr *)&peer,sizeof(peer));
  if(connected<0 && errno!=EINPROGRESS){report[@"errno"]=@(errno);close(fd);return report;}
  struct pollfd writable={fd,POLLOUT,0};
  int socketError=0;socklen_t errorSize=sizeof(socketError);
  if(poll(&writable,1,5000)<=0 || getsockopt(fd,SOL_SOCKET,SO_ERROR,&socketError,&errorSize)<0 || socketError){
    report[@"error"]=@"connect_failed";report[@"socket_errno"]=@(socketError);close(fd);return report;
  }
  report[@"connected"]=@YES;
  NSString *wire=[NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:%@\r\nConnection: close\r\n\r\n",url.percentEncodedPath,url.port];
  NSData *request=[wire dataUsingEncoding:NSUTF8StringEncoding];
  const char *bytes=(const char *)request.bytes;NSUInteger sent=0;
  while(sent<request.length && NSDate.timeIntervalSinceReferenceDate<deadline){
    struct pollfd wait={fd,POLLOUT,0};
    if(poll(&wait,1,100)<=0)continue;
    ssize_t n=send(fd,bytes+sent,request.length-sent,0);
    if(n>0)sent+=(NSUInteger)n;
    else if(n<0 && errno!=EINTR && errno!=EAGAIN){report[@"send_errno"]=@(errno);break;}
  }
  NSMutableData *response=[NSMutableData data];
  while(sent==request.length && response.length<65536 && NSDate.timeIntervalSinceReferenceDate<deadline){
    struct pollfd wait={fd,POLLIN,0};
    if(poll(&wait,1,100)<=0)continue;
    char buffer[2048];ssize_t n=recv(fd,buffer,sizeof(buffer),0);
    if(n>0)[response appendBytes:buffer length:(NSUInteger)n];
    else if(n==0)break;
    else if(errno!=EINTR && errno!=EAGAIN){report[@"read_errno"]=@(errno);break;}
  }
  close(fd);report[@"response_bytes"]=@(response.length);
  NSString *text=[[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
  report[@"http_ok"]=@([text hasPrefix:@"HTTP/1.1 200 "] || [text hasPrefix:@"HTTP/1.0 200 "]);
  NSRange split=[text rangeOfString:@"\r\n\r\n"];
  if(text && split.location!=NSNotFound){
    NSData *body=[[text substringFromIndex:NSMaxRange(split)] dataUsingEncoding:NSUTF8StringEncoding];
    id value=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if([value isKindOfClass:NSDictionary.class] && [value[@"runtime"] isKindOfClass:NSString.class])
      report[@"runtime"]=value[@"runtime"];
  }
  return report;
}
