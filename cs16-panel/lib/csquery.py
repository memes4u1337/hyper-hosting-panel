#!/usr/bin/env python3
from __future__ import annotations
import socket, struct, time
from dataclasses import dataclass
from typing import Any

HEADER=b'\xff\xff\xff\xff'

class QueryError(RuntimeError):
    pass


def _z(data: bytes, off: int):
    end=data.find(b'\x00',off)
    if end < 0: raise QueryError('Malformed zero terminated string')
    return data[off:end].decode('utf-8','replace'), end+1


def _recv(host: str, port: int, payload: bytes, timeout: float=1.4, size: int=65535):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    s.settimeout(timeout)
    started=time.perf_counter()
    try:
        s.sendto(payload,(host,port))
        data,_=s.recvfrom(size)
        return data, (time.perf_counter()-started)*1000.0
    except OSError as exc:
        raise QueryError(str(exc)) from exc
    finally:
        s.close()


def info(host: str, port: int, timeout: float=1.4) -> dict[str,Any]:
    data,ping=_recv(host,port,HEADER+b'TSource Engine Query\x00',timeout)
    if not data.startswith(HEADER): raise QueryError('Bad A2S header')
    kind=data[4:5]; o=5
    out={'ping_ms':round(ping,2)}
    if kind == b'I':
        if len(data)<6: raise QueryError('Short A2S_INFO')
        proto=data[o]; o+=1
        name,o=_z(data,o); map_name,o=_z(data,o); folder,o=_z(data,o); game,o=_z(data,o)
        if o+7>len(data): raise QueryError('Short A2S_INFO payload')
        appid=struct.unpack_from('<H',data,o)[0]; o+=2
        players,maxp,bots=struct.unpack_from('<BBB',data,o); o+=3
        server_type=chr(data[o]); env=chr(data[o+1]); o+=2
        visibility=bool(data[o]); vac=bool(data[o+1]); o+=2
        out.update({'protocol':proto,'name':name,'map':map_name,'folder':folder,'game':game,'appid':appid,
                    'players':players,'max_players':maxp,'bots':bots,'server_type':server_type,'environment':env,
                    'password':visibility,'vac':vac})
        return out
    if kind == b'm':  # old GoldSrc response
        address,o=_z(data,o); name,o=_z(data,o); map_name,o=_z(data,o); folder,o=_z(data,o); game,o=_z(data,o)
        if o+5>len(data): raise QueryError('Short GoldSrc info payload')
        players,maxp,proto=struct.unpack_from('<BBB',data,o); o+=3
        server_type=chr(data[o]); env=chr(data[o+1]); o+=2
        visibility=bool(data[o]) if o < len(data) else False; o+=1
        mod=bool(data[o]) if o < len(data) else False; o+=1
        if mod and o < len(data):
            try:
                _,o=_z(data,o); _,o=_z(data,o); o += 1+4+4+1+1
            except Exception:
                pass
        vac=bool(data[o]) if o < len(data) else False; o+=1
        bots=data[o] if o < len(data) else 0
        out.update({'address':address,'name':name,'map':map_name,'folder':folder,'game':game,'players':players,
                    'max_players':maxp,'protocol':proto,'server_type':server_type,'environment':env,
                    'password':visibility,'vac':vac,'bots':bots})
        return out
    raise QueryError(f'Unsupported info response {kind!r}')


def players(host: str, port: int, timeout: float=1.4) -> list[dict[str,Any]]:
    data,_=_recv(host,port,HEADER+b'U'+b'\xff\xff\xff\xff',timeout)
    if not data.startswith(HEADER+b'A') or len(data)<9:
        raise QueryError('No A2S_PLAYER challenge')
    challenge=data[5:9]
    data,_=_recv(host,port,HEADER+b'U'+challenge,timeout)
    if not data.startswith(HEADER+b'D') or len(data)<6:
        raise QueryError('Bad A2S_PLAYER response')
    count=data[5]; o=6; result=[]
    for _ in range(count):
        if o>=len(data): break
        idx=data[o]; o+=1
        name,o=_z(data,o)
        if o+8>len(data): break
        score=struct.unpack_from('<i',data,o)[0]; o+=4
        duration=struct.unpack_from('<f',data,o)[0]; o+=4
        result.append({'index':idx,'name':name,'score':score,'duration':round(max(0.0,duration),1)})
    return result


def rcon(host: str, port: int, password: str, command: str, timeout: float=2.0) -> str:
    if not password: raise QueryError('RCON password is empty')
    if '\n' in command or '\r' in command: raise QueryError('RCON command must be one line')
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(HEADER+b'challenge rcon\n',(host,port))
        data,_=s.recvfrom(65535)
        text=data[4:].decode('utf-8','replace').strip() if data.startswith(HEADER) else data.decode('utf-8','replace').strip()
        parts=text.split()
        if len(parts)<3 or parts[0].lower()!='challenge' or parts[1].lower()!='rcon':
            raise QueryError('Invalid RCON challenge')
        challenge=parts[2]
        payload=f'rcon {challenge} "{password.replace(chr(34),"")}" {command}\n'.encode('utf-8','replace')
        s.sendto(HEADER+payload,(host,port))
        chunks=[]
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            try:
                data,_=s.recvfrom(65535)
            except socket.timeout:
                break
            if data.startswith(HEADER): data=data[4:]
            chunks.append(data.decode('utf-8','replace').rstrip('\x00\r\n'))
            if len(data)<1200: break
        return '\n'.join(x for x in chunks if x).strip()
    except OSError as exc:
        raise QueryError(str(exc)) from exc
    finally:
        s.close()
