# drivelog — wk2-drivelog

comma 디바이스 드라이브로그 보관용 브랜치.

- 파일 형식: `{dongle}_{route}--{seg}--rlog.zst`
- 보관 정책: 최신 route 일부만 유지 (용량 한도 관리)
- qlog 는 rlog 의 축약본이라 저장하지 않음

## 스크립트

```bash
# 기기에서 받아 업로드
python3 upload_ssh_drivelog.py --device C4-CE1N

# 오래된 route 정리
python3 prune_drivelog.py --device C4-CE1N --rebuild --keep 5 --yes

# 상태 확인
bash check_drivelog.sh
```
