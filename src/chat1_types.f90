module chat1_types
  implicit none
  private

  integer, parameter, public :: CHAT1_KIND_NONE  = 0
  integer, parameter, public :: CHAT1_KIND_HELLO = 1
  integer, parameter, public :: CHAT1_KIND_MSG   = 2
  integer, parameter, public :: CHAT1_KIND_WANT  = 3
  integer, parameter, public :: CHAT1_KIND_ERR   = 4

  integer, parameter, public :: CHAT1_MAX_LINE_LEN = 65535
  integer, parameter, public :: CHAT1_NODE_ID_LEN = 64
  integer, parameter, public :: CHAT1_MSG_ID_LEN = 64
  integer, parameter, public :: CHAT1_PUBKEY_B64_LEN = 43
  integer, parameter, public :: CHAT1_SIG_B64_LEN = 86
  integer, parameter, public :: CHAT1_MAX_ROOM_LEN = 64
  integer, parameter, public :: CHAT1_MAX_BODY_BYTES = 4096
  integer, parameter, public :: CHAT1_MAX_ERR_CODE_LEN = 32

  character(len=*), parameter, public :: CHAT1_VERSION = 'CHAT/1'
  character(len=*), parameter, public :: CHAT1_MODE_PEER = 'peer'
  character(len=*), parameter, public :: CHAT1_MODE_HUB = 'hub'
  character(len=*), parameter, public :: CHAT1_MODE_PEER_HUB = 'peer,hub'

  type, public :: chat1_error
    logical :: ok = .true.
    character(len=:), allocatable :: code
    character(len=:), allocatable :: message
  end type chat1_error

  type, public :: hello_frame
    character(len=:), allocatable :: node_id
    character(len=:), allocatable :: pubkey_b64
    character(len=:), allocatable :: mode
  end type hello_frame

  type, public :: msg_frame
    character(len=:), allocatable :: room_id
    character(len=:), allocatable :: msg_id
    character(len=:), allocatable :: author_id
    character(len=:), allocatable :: ts_ms
    character(len=:), allocatable :: body_b64
    character(len=:), allocatable :: body_text
    character(len=:), allocatable :: sig_b64
  end type msg_frame

  type, public :: want_frame
    character(len=:), allocatable :: room_id
    character(len=:), allocatable :: since_id
  end type want_frame

  type, public :: err_frame
    character(len=:), allocatable :: err_code
    character(len=:), allocatable :: err_text
  end type err_frame

  type, public :: chat1_frame
    integer :: kind = CHAT1_KIND_NONE
    type(hello_frame) :: hello
    type(msg_frame) :: msg
    type(want_frame) :: want
    type(err_frame) :: err
  end type chat1_frame

  public :: chat1_clear_error, chat1_set_error, chat1_clear_frame

contains

  subroutine chat1_clear_error(err)
    type(chat1_error), intent(out) :: err

    err%ok = .true.
    err%code = ''
    err%message = ''
  end subroutine chat1_clear_error

  subroutine chat1_set_error(err, code, message)
    type(chat1_error), intent(out) :: err
    character(len=*), intent(in) :: code
    character(len=*), intent(in) :: message

    err%ok = .false.
    err%code = trim(code)
    err%message = trim(message)
  end subroutine chat1_set_error

  subroutine chat1_clear_frame(frame)
    type(chat1_frame), intent(out) :: frame

    frame%kind = CHAT1_KIND_NONE

    frame%hello%node_id = ''
    frame%hello%pubkey_b64 = ''
    frame%hello%mode = ''

    frame%msg%room_id = ''
    frame%msg%msg_id = ''
    frame%msg%author_id = ''
    frame%msg%ts_ms = ''
    frame%msg%body_b64 = ''
    frame%msg%body_text = ''
    frame%msg%sig_b64 = ''

    frame%want%room_id = ''
    frame%want%since_id = ''

    frame%err%err_code = ''
    frame%err%err_text = ''
  end subroutine chat1_clear_frame

end module chat1_types
