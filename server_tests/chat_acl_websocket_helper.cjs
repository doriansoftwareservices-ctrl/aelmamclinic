'use strict';
const assert=require('node:assert/strict');

// Native Node22 WebSocket, deliberately restricted to the owned loopback engine.
module.exports=function subscribeMessages(base,authorization,room){
  const url=new URL('/v1/graphql',base);
  assert.equal(url.hostname,'127.0.0.1');assert.equal(url.protocol,'http:');
  assert.match(room,/^[0-9a-f-]{36}$/);assert.equal(typeof WebSocket,'function');
  url.protocol='ws:';
  const socket=new WebSocket(url,'graphql-ws');
  let rows=null,failure=null,started=false;
  const waiters=new Set();
  function fail(error){
    failure=error;
    for(const waiter of waiters){clearTimeout(waiter.timer);waiter.reject(error);}
    waiters.clear();
  }
  const closed=new Promise(resolve=>socket.addEventListener('close',()=>{
    fail(new Error('Owned local subscription closed'));resolve();
  }));
  socket.addEventListener('error',()=>fail(new Error('Owned local WebSocket transport failed')));
  socket.addEventListener('open',()=>socket.send(JSON.stringify({type:'connection_init',payload:{
    headers:{authorization,'x-hasura-role':'user'},
  }})));
  socket.addEventListener('message',event=>{
    let value;
    try{value=JSON.parse(event.data);}catch{fail(new Error('Invalid local subscription payload'));return;}
    if(value.type==='connection_ack'&&!started){
      started=true;
      socket.send(JSON.stringify({type:'start',id:'scope',payload:{query:
        `subscription{chat_messages(where:{conversation_id:{_eq:"${room}"}},order_by:{created_at:asc}){id}}`,
      }}));
    }else if(value.type==='data'&&value.id==='scope'){
      if(value.payload.errors){fail(new Error('Owned local subscription GraphQL failure'));return;}
      rows=value.payload.data.chat_messages;
      for(const waiter of waiters){
        if(waiter.predicate(rows)){clearTimeout(waiter.timer);waiters.delete(waiter);waiter.resolve(rows);}
      }
    }else if(['error','connection_error'].includes(value.type)){
      fail(new Error('Owned local subscription authorization failure'));
    }
  });
  return {
    waitFor(predicate){
      if(failure)return Promise.reject(failure);
      if(rows!==null&&predicate(rows))return Promise.resolve(rows);
      return new Promise((resolve,reject)=>{
        const waiter={predicate,resolve,reject,timer:null};
        waiter.timer=setTimeout(()=>{waiters.delete(waiter);reject(new Error('Owned local subscription state deadline'));},7000);
        waiters.add(waiter);
      });
    },
    async close(){
      if(socket.readyState===WebSocket.CLOSED)return;
      if(socket.readyState===WebSocket.OPEN){
        socket.send(JSON.stringify({type:'stop',id:'scope'}));
        socket.send(JSON.stringify({type:'connection_terminate'}));
      }
      socket.close();
      await closed;
    },
  };
};
