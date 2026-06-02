# /higgsfield — Higgsfield 미디어 생성

Higgsfield CLI를 통해 이미지 또는 영상을 생성합니다.

## 사용법

```
/higgsfield <작업 설명>
```

## 예시

- `/higgsfield 제품 광고 이미지 생성: 스마트폰, 미니멀 배경, 4K`
- `/higgsfield 15초 소개 영상 생성: 인공지능 출입관리 시스템`
- `/higgsfield Soul V2로 캐릭터 일관성 있는 마케팅 이미지 생성`

## 동작

이 커맨드가 실행되면 NCO smart-router가 `higgsfield` 프로바이더로 라우팅하여
다음을 수행합니다:

1. 인증 상태 확인 (`higgsfield auth status`)
2. 미인증 시: `higgsfield auth login` 실행 안내
3. 모델 선택 및 생성 실행

## 지원 모델

- **이미지**: FLUX.2, Soul V2
- **영상**: Veo 3.1, Kling v3.0
- **마케팅**: Marketing Studio

## 인증

```bash
higgsfield auth login   # 브라우저 로그인 (short-lived token)
```

## 주의사항

- auth token은 단기 유효 — 만료 시 재로그인 필요
- 코드 작업에는 사용하지 않음 (미디어 전용)
- NCO 라우팅 키워드: 이미지 생성, 영상 생성, image gen, video gen
