# Modal Analysis

## 범위

이 문서는 `/Users/harry/project/front-cocoin` 앱 안의 모달, 모달성 오버레이, 알림 레이어를 빠짐없이 정리한 분석 문서다.

분석 기준:

- 전역 상태 기반 모달 시스템
- 개별 시각 컴포넌트 변형
- 실제 사용 중인 호출 지점
- 코드에 남아 있지만 현재 비활성인 모달/오버레이
- 의존성 버전과 현재 구현 방식의 관계

기준 의존성은 `Next 14.2.3`, `React 18`, `@reduxjs/toolkit 1.9.0`, `@tanstack/react-query 5.32.1`, `framer-motion 9.0.2`, `@material-tailwind/react 2.1.10` 이다. 출처: `package.json`

## 결론 요약

이 앱의 정식 전역 모달 시스템은 정확히 4계열이다.

1. `alert`
2. `toast`
3. `confirm`
4. `noti`

상태 정의 기준 출처:

- `redux/reducers/modal/index.ts`

시각 컴포넌트 기준 총 개수는 11개다.

1. Alert 계열 5개
2. Confirm 계열 4개
3. Toast 계열 1개
4. Noti 계열 1개

추가로 모달처럼 동작하거나 모달 인프라를 공유하는 비정형 오버레이가 3개 있다.

1. 포털 기반 테스트용 오버레이
2. 우측 사이드바 드로어 오버레이
3. 구형 소켓 경로의 브라우저 native `alert()`

## 전역 마운트 구조

전역 모달 시스템은 `app/layout.tsx` 에서 항상 마운트된다.

관련 코드:

- `app/layout.tsx`

마운트되는 전역 렌더러:

1. `NotiUtil`
2. `ConfirmUtil`
3. `ToastUtil`
4. `AlertUtil`

같은 레이아웃에 `div#root-modal` 도 존재한다. 다만 이 포털 루트는 전역 모달 4계열이 직접 쓰지 않고, 테스트용 `usePortal` 에서만 사용한다.

## 상태 구조

모달 상태는 `redux/reducers/modal/index.ts` 의 `createSlice` 하나로 관리된다.

정확한 상태 필드:

1. `alert: AlertType[]`
2. `toast: ToastType[]`
3. `confirm: ConfirmType[]`
4. `noti: NotiType[]`

액션 목록:

1. `addAlert`
2. `deleteAlert`
3. `deleteAllAlert`
4. `addToast`
5. `deleteToast`
6. `addConfirm`
7. `deleteConfirm`
8. `addNoti`
9. `deleteNoti`
10. `deleteAllNoti`

공통 특징:

- 모든 `add*` 액션은 `uuid` 를 생성한다.
- 새 항목은 배열 앞에 prepend 된다.
- `alert`, `toast`, `confirm` 은 사실상 "맨 앞 항목" 위주로 그려진다.
- `noti` 만 여러 항목을 동시에 map 으로 렌더링한다.

관련 코드:

- `redux/reducers/modal/index.ts`
- `redux/store.ts`

## 전체 종류 인벤토리

### 1. Alert 계열

렌더러:

- `utils/alertUtil.tsx`

시각 변형:

1. `component/common/modal/alert/BasicAlert.tsx`
2. `component/common/modal/alert/AlertInfo.tsx`
3. `component/common/modal/alert/AlertDanger.tsx`
4. `component/common/modal/alert/AlertSuc.tsx`
5. `component/common/modal/alert/AlertWarn.tsx`

렌더링 분기 기준:

- `type == null` -> `BasicAlert`
- `type == 'info'` -> `AlertInfo`
- `type == 'danger'` -> `AlertDanger`
- `type == 'suc'` -> `AlertSuc`
- `type == 'warn'` -> `AlertWarn`

동작 특성:

- 화면 상단 중앙에 fixed 배너로 뜬다.
- `ModalBg` 를 쓰지 않는다.
- `framer-motion` 의 `basicAlertAnim` 으로 위에서 내려오는 애니메이션을 쓴다.
- `modal.alert.length > 0` 이면 1.5초 뒤 `deleteAllAlert()` 가 호출된다.
- 따라서 배열형 상태지만 UX 는 "큐" 보다는 "일괄 소거되는 임시 배너" 에 가깝다.

관련 코드:

- `utils/alertUtil.tsx`
- `motion/BasicAnim.ts`

### 2. Confirm 계열

렌더러:

- `utils/confirmUtil.tsx`

시각 변형:

1. `component/common/modal/confirm/BasicConfirm.tsx`
2. `component/common/modal/confirm/ConfirmSuc.tsx`
3. `component/common/modal/confirm/ConfirmWarm.tsx`
4. `component/common/modal/confirm/ConfirmDanger.tsx`

렌더링 분기 기준:

- `type == null` -> `BasicConfirm`
- `type == 'suc'` -> `ConfirmSuc`
- `type == 'warn'` -> `ConfirmWarm`
- `type == 'danger'` -> `ConfirmDanger`

동작 특성:

- 화면 중앙 영역에 fixed 로 뜬다.
- `ModalBg` 를 사용한다.
- `framer-motion` 의 `basicConfirmAnim` 을 사용한다.
- `modal.confirm[0]` 하나만 그린다.
- `modal.toast.length !== 0` 이면 confirm 을 렌더링하지 않는다.
- 즉 toast 가 confirm 보다 우선순위가 높다.

버튼 동작:

- 각 confirm 컴포넌트는 `btn1Text`, `btn1Func`, `btn2Text`, `btn2Func` 를 받는다.
- 기본 텍스트는 각각 `취소`, `확인` 이다.
- 버튼 클릭 시 사용자 콜백 실행 뒤 `closeFunc()` 를 다시 호출한다.
- `btn1Func` 또는 `btn2Func` 가 이미 close 를 수행해도 추가로 close 가 한 번 더 호출될 수 있다.

관련 코드:

- `utils/confirmUtil.tsx`
- `component/common/modal/confirm/*.tsx`
- `component/common/modal/modalBg/index.tsx`
- `motion/BasicAnim.ts`

### 3. Toast 계열

렌더러:

- `utils/toastUtil.tsx`

시각 변형:

1. `component/common/modal/toast/BasicToast.tsx`

동작 특성:

- 중앙 영역에 fixed 로 뜬다.
- `ModalBg` 를 사용한다.
- `basicToastAnim` 으로 fade in/out 한다.
- 내부 `Progress` 는 `@material-tailwind/react` 컴포넌트다.
- 5ms 간격으로 0.1씩 증가하는 진행 상태를 가지며, 대략 5초 후 자동 close 된다.
- 수동 닫기 버튼도 있다.

버튼 동작:

- `btnFunc` 가 있으면 실행 후 close
- 없으면 close 만 수행

관련 코드:

- `utils/toastUtil.tsx`
- `component/common/modal/toast/BasicToast.tsx`
- `component/common/modal/modalBg/index.tsx`

### 4. Noti 계열

렌더러:

- `utils/notiUtil.tsx`

시각 변형:

1. `component/common/modal/noti/BasicNoti.tsx`

동작 특성:

- 우상단에 스택형으로 여러 개가 동시에 뜬다.
- `basicNotiAnim` 으로 오른쪽에서 슬라이드 인한다.
- `modal.noti` 를 map 으로 모두 렌더링한다.
- 자동 소멸이 없다.
- 개별 닫기 가능
- 2개 이상이면 "모두지우기" 버튼이 뜬다.

주의:

- `BasicNoti.tsx` 는 `ModalBg` 를 import 하지만 실제로 렌더링하지 않는다.
- 타입에는 `type` 필드가 있으나, 시각 분기는 없다.

관련 코드:

- `utils/notiUtil.tsx`
- `component/common/modal/noti/BasicNoti.tsx`
- `motion/BasicAnim.ts`

## 공통 오버레이 인프라

### ModalBg

공통 배경 레이어는 `component/common/modal/modalBg/index.tsx` 이다.

역할:

1. 전체 화면 반투명 검은 배경 렌더링
2. body scroll lock
3. 필요 시 클릭으로 닫기

현재 사용처:

1. Confirm 계열 4개
2. Toast 계열 1개
3. RightSidebar 오버레이

현재 미사용:

- Noti
- Alert

주의점:

- `useEffect` cleanup 에서 `modal.toast.length + modal.confirm.length > 1` 인 경우 body scroll 복구를 건너뛴다.
- 이 로직은 mount 시점 상태를 기준으로 동작하고, 상태 변화 동기화가 없다.
- modal queue 가 겹치는 경우 body scroll 복구가 일관되지 않을 가능성이 있다.

관련 코드:

- `component/common/modal/modalBg/index.tsx`

## 실제 사용 지점 분석

아래는 현재 live code 기준 dispatch 또는 렌더링 경로가 확인된 지점들이다.

### Alert 실제 사용

1. 로그인 성공/실패/로그아웃/로그인 필요
   - `api/service/auth/biz/useAuthService.ts`
2. 코인 주문 성공/실패
   - `api/service/cocoin/biz/useCocoinService.ts`
3. 로그인 폼 검증 실패
   - `component/module/login/index.tsx`
4. 회원가입 폼 검증 실패
   - `component/module/join/index.tsx`
5. 코인 주문 폼 검증 실패
   - `component/module/coin/coin/OrderBoxBuy.tsx`
6. 슬롯 게임 테스트 완료
   - `component/module/coin/game/basic/index.tsx`
7. 소켓 `test` 메시지 수신
   - `socket/v2/SocketConnections.tsx`
8. 개발용 헤더 테스트 버튼
   - `component/common/header/SecondHeader.tsx`

실제 사용되는 alert 타입:

1. `null`
2. `danger`
3. `suc`

코드상 존재하지만 현재 사용 호출이 없는 타입:

1. `info`
2. `warn`

### Confirm 실제 사용

1. 메인 화면 "준비중입니다" 안내
   - `component/module/main/MainTwoCard.tsx`
   - 기본형 confirm 사용
2. 코인 주문 확인 모달
   - `component/module/coin/coin/OrderBoxBuy.tsx`
   - `warn` confirm 사용
3. 개발용 헤더 테스트 버튼
   - `component/common/header/SecondHeader.tsx`

실제 사용되는 confirm 타입:

1. `null`
2. `warn`

코드상 존재하지만 현재 사용 호출이 없는 타입:

1. `suc`
2. `danger`

### Toast 실제 사용

1. 개발용 헤더 테스트 버튼
   - `component/common/header/SecondHeader.tsx`

실제 사용되는 toast 타입:

1. 기본형 only

주의:

- `ToastType` 에 `type` 필드가 있지만 렌더링 분기에서 사용하지 않는다.

### Noti 실제 사용

1. 소켓 `notice` 메시지 수신
   - `socket/v2/SocketConnections.tsx`
2. 개발용 헤더 테스트 버튼
   - `component/common/header/SecondHeader.tsx`

실제 사용되는 noti 타입:

1. 기본형 only

주의:

- `NotiType` 에 `type` 필드가 있지만 렌더링 분기에서 사용하지 않는다.

## 개발용 테스트 트리거

`component/common/header/SecondHeader.tsx` 에 alert, toast, confirm, noti 를 강제로 띄우는 테스트 버튼 4개가 있다.

테스트 함수:

1. `alertTest`
2. `toastTest`
3. `confirmTest`
4. `notiTest`

이 헤더는 `component/common/layout/BasicLayout.tsx` 에서 실제 마운트되고 있다.

관련 코드:

- `component/common/header/SecondHeader.tsx`
- `component/common/layout/BasicLayout.tsx`

## 소켓 연동과 모달

현재 실사용 소켓 경로는 v2 이다.

실사용:

- `socket/v2/SocketConnections.tsx`

동작:

1. `notice` -> `addNoti({ title: '공지사항', msg: data.message })`
2. `test` -> `addAlert({ msg: data.message })`
3. `logout` -> 소켓 disconnect

보조 테스트 UI:

- `component/common/test/SocketTest.tsx`

이 테스트 컴포넌트는 `BasicLayout` 에 실제로 마운트되어 있다. 따라서 코인 레이아웃 하위 화면에서는 소켓 테스트 입력창이 노출된다.

관련 코드:

- `socket/v2/SocketConnections.tsx`
- `component/common/test/SocketTest.tsx`
- `component/common/layout/BasicLayout.tsx`

## 비정형 오버레이 1: 포털 기반 테스트 모달

`hooks/usePortal.tsx` 는 전역 모달 시스템과 별개인 독립 포털 훅이다.

특징:

1. `#root-modal` 에 포털 렌더링
2. 자체 `isOpen` 상태 사용
3. 배경 클릭으로 닫힘
4. fixed 검은 배경 포함

사용처:

- `component/common/test/TestLoginForm.tsx`

현재 상태:

- `component/module/main/index.tsx` 에서 `TestLoginForm` 렌더링이 주석 처리되어 있어 실제 사용자 화면에는 비활성

따라서 이 포털 모달은 코드상 존재하지만 현재 앱의 live modal system 에 포함되지는 않는다.

관련 코드:

- `hooks/usePortal.tsx`
- `component/common/test/TestLoginForm.tsx`
- `component/module/main/index.tsx`

## 비정형 오버레이 2: 우측 사이드바 드로어

`component/common/rightSidebar/index.tsx` 는 `ModalBg` 를 사용해 열리는 우측 drawer 형태의 오버레이다.

특징:

1. 모달처럼 배경 dim 을 깐다.
2. 본체는 `aside`
3. 내부 컨텐츠는 `BasicRightSidebar`
4. 상태는 `common.isRightSidebar`

문제는 현재 마운트 경로가 막혀 있다는 점이다.

`component/common/layout/BasicLayout.tsx` 에서 `RightSidebar` 가 주석 처리되어 있다.

즉:

- 구현은 존재
- 열림 상태 slice 도 존재
- close 액션도 존재
- 하지만 현재 앱에서는 컴포넌트가 마운트되지 않아 사실상 죽은 UI 다

관련 코드:

- `component/common/rightSidebar/index.tsx`
- `component/common/rightSidebar/BasicRightSidebar.tsx`
- `redux/reducers/common/index.ts`
- `component/common/layout/BasicLayout.tsx`

## 비정형 오버레이 3: 구형 native alert

구형 소켓 경로 `socket/v1/initSocket.ts` 에 브라우저 native `alert(quote.content)` 가 남아 있다.

현재 확인 결과:

- `app/StoreProvider.tsx` 에서 v1 소켓 연결 코드는 주석 처리되어 있다.
- 현재 실사용 소켓 경로는 v2 이다.

따라서 native alert 는 레거시 잔재이며 현재 UX 경로에는 들어오지 않는다.

관련 코드:

- `socket/v1/initSocket.ts`
- `app/StoreProvider.tsx`

## 사용 중인 종류와 미사용 종류 정리

### 실제 사용자 흐름에서 사용 중

1. 기본 Alert
2. Danger Alert
3. Success Alert
4. 기본 Confirm
5. Warn Confirm
6. 기본 Toast
7. 기본 Noti

### 코드상 존재하지만 현재 호출 없음

1. Info Alert
2. Warn Alert
3. Success Confirm
4. Danger Confirm

### 코드상 존재하지만 현재 live 화면 비활성

1. `usePortal` 기반 테스트 모달
2. RightSidebar 오버레이
3. v1 소켓 native alert

## 구현 방식 평가

### 장점

1. 전역 렌더러가 `app/layout.tsx` 에 고정돼 있어 어디서든 dispatch 만으로 띄울 수 있다.
2. `Redux Toolkit` slice 하나로 모달 상태를 관리해 진입 장벽이 낮다.
3. `framer-motion` 으로 각 계열 애니메이션이 분리되어 있다.
4. confirm, toast, noti 는 open/close callback 을 지원한다.

### 한계

1. `Next 14 + React 18` 기준으로도 동작은 가능하지만, 전역 모달이 포털 대신 일반 fixed 렌더링에 의존해 layering 제어가 느슨하다.
2. 타입 정의와 렌더링 구현이 불일치한다.
   - `ToastType.type` 정의는 있으나 시각 분기 없음
   - `NotiType.type` 정의는 있으나 시각 분기 없음
3. alert 는 배열 상태지만 `deleteAllAlert()` 로 한 번에 지워져 큐 의미가 약하다.
4. confirm 은 toast 존재 시 강제로 숨겨진다.
5. body scroll lock 은 `ModalBg` 내부 부수효과에 의존하며 중첩 케이스에 취약하다.
6. 일부 confirm 파일은 JSX 속성으로 `fill-rule`, `clip-rule` 를 쓰고 있어 React 관점에서는 구식 표기다.
7. `redux/store.ts` 의 serializable ignore 설정은 `noti` 를 빠뜨려 두었다.
8. 전역 모달 시스템과 테스트성 UI 가 분리되지 않아 운영 코드와 개발 편의 코드가 섞여 있다.

## 파일별 역할 정리

### 핵심 정의

- `redux/reducers/modal/index.ts`
- `redux/store.ts`

### 전역 렌더러

- `utils/alertUtil.tsx`
- `utils/confirmUtil.tsx`
- `utils/toastUtil.tsx`
- `utils/notiUtil.tsx`

### 시각 컴포넌트

- `component/common/modal/alert/BasicAlert.tsx`
- `component/common/modal/alert/AlertInfo.tsx`
- `component/common/modal/alert/AlertDanger.tsx`
- `component/common/modal/alert/AlertSuc.tsx`
- `component/common/modal/alert/AlertWarn.tsx`
- `component/common/modal/confirm/BasicConfirm.tsx`
- `component/common/modal/confirm/ConfirmSuc.tsx`
- `component/common/modal/confirm/ConfirmWarm.tsx`
- `component/common/modal/confirm/ConfirmDanger.tsx`
- `component/common/modal/toast/BasicToast.tsx`
- `component/common/modal/noti/BasicNoti.tsx`
- `component/common/modal/modalBg/index.tsx`

### 사용처

- `api/service/auth/biz/useAuthService.ts`
- `api/service/cocoin/biz/useCocoinService.ts`
- `component/module/login/index.tsx`
- `component/module/join/index.tsx`
- `component/module/main/MainTwoCard.tsx`
- `component/module/coin/coin/OrderBoxBuy.tsx`
- `component/module/coin/game/basic/index.tsx`
- `socket/v2/SocketConnections.tsx`
- `component/common/header/SecondHeader.tsx`

### 비활성/레거시 관련

- `hooks/usePortal.tsx`
- `component/common/test/TestLoginForm.tsx`
- `component/common/rightSidebar/index.tsx`
- `component/common/rightSidebar/BasicRightSidebar.tsx`
- `socket/v1/initSocket.ts`
- `app/StoreProvider.tsx`

## 최종 정리

현재 이 앱의 모달 시스템은 "전역 Redux 기반 4계열 + 비활성 테스트/레거시 오버레이" 구조다.

정식 분류:

1. Alert
2. Toast
3. Confirm
4. Noti

실사용 시각 분류:

1. 기본 Alert
2. Danger Alert
3. Success Alert
4. 기본 Confirm
5. Warn Confirm
6. 기본 Toast
7. 기본 Noti

코드상 전체 시각 컴포넌트 분류:

1. BasicAlert
2. AlertInfo
3. AlertDanger
4. AlertSuc
5. AlertWarn
6. BasicConfirm
7. ConfirmSuc
8. ConfirmWarm
9. ConfirmDanger
10. BasicToast
11. BasicNoti

이 문서 기준으로 누락 없이 포함된 대상:

- 전역 모달 4계열
- 시각 변형 11개
- 공통 오버레이 1개
- 테스트 트리거 4개
- 실제 사용처 전부
- 비활성 포털 모달
- 비활성 우측 드로어 오버레이
- 레거시 native alert
