module chat1_crypto
  use chat1_types, only: chat1_error, chat1_clear_error, chat1_set_error
  implicit none
  private

  public :: chat1_sha256_text, chat1_sha256_b64url, chat1_verify_ed25519, chat1_crypto_selftest

contains

  subroutine chat1_sha256_text(text, digest_hex, err)
    character(len=*), intent(in) :: text
    character(len=:), allocatable, intent(out) :: digest_hex
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: input_path, output_path, backend_path, command, output
    integer :: exitstat, cmdstat

    call chat1_clear_error(err)
    digest_hex = ''

    input_path = temp_path('sha256_input.bin')
    output_path = temp_path('sha256_output.txt')
    backend_path = backend_script_path()

    call write_binary_file(input_path, text, err)
    if (.not. err%ok) return

    command = 'python3 "' // backend_path // '" sha256-file "' // input_path // '" "' // output_path // '"'
    call execute_command_line(command, exitstat=exitstat, cmdstat=cmdstat)
    if (cmdstat /= 0 .or. exitstat /= 0) then
      call chat1_set_error(err, 'crypto-failed', 'sha256 backend failed')
      call cleanup_paths(input_path, output_path)
      return
    end if

    call read_text_file(output_path, output, err)
    call cleanup_paths(input_path, output_path)
    if (.not. err%ok) return

    digest_hex = trim(strip_newline(output))
  end subroutine chat1_sha256_text

  subroutine chat1_sha256_b64url(value, digest_hex, err)
    character(len=*), intent(in) :: value
    character(len=:), allocatable, intent(out) :: digest_hex
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: backend_path, output_path, command, output
    integer :: exitstat, cmdstat

    call chat1_clear_error(err)
    digest_hex = ''

    output_path = temp_path('sha256_b64_output.txt')
    backend_path = backend_script_path()

    command = 'python3 "' // backend_path // '" sha256-b64url ' // trim(value) // ' "' // output_path // '"'
    call execute_command_line(command, exitstat=exitstat, cmdstat=cmdstat)
    if (cmdstat /= 0 .or. exitstat /= 0) then
      call chat1_set_error(err, 'crypto-failed', 'sha256 base64url backend failed')
      call cleanup_paths(output_path)
      return
    end if

    call read_text_file(output_path, output, err)
    call cleanup_paths(output_path)
    if (.not. err%ok) return

    digest_hex = trim(strip_newline(output))
  end subroutine chat1_sha256_b64url

  subroutine chat1_verify_ed25519(pubkey_b64, sig_b64, message, is_valid, err)
    character(len=*), intent(in) :: pubkey_b64
    character(len=*), intent(in) :: sig_b64
    character(len=*), intent(in) :: message
    logical, intent(out) :: is_valid
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: input_path, output_path, backend_path, command, output
    integer :: exitstat, cmdstat

    call chat1_clear_error(err)
    is_valid = .false.

    input_path = temp_path('verify_input.bin')
    output_path = temp_path('verify_output.txt')
    backend_path = backend_script_path()

    call write_binary_file(input_path, message, err)
    if (.not. err%ok) return

    command = 'python3 "' // backend_path // '" verify-ed25519 ' // trim(pubkey_b64) // ' ' // trim(sig_b64) // ' "' // input_path // '" "' // output_path // '"'
    call execute_command_line(command, exitstat=exitstat, cmdstat=cmdstat)
    if (cmdstat /= 0 .or. exitstat /= 0) then
      call chat1_set_error(err, 'crypto-failed', 'ed25519 verify backend failed')
      call cleanup_paths(input_path, output_path)
      return
    end if

    call read_text_file(output_path, output, err)
    call cleanup_paths(input_path, output_path)
    if (.not. err%ok) return

    is_valid = trim(strip_newline(output)) == 'OK'
  end subroutine chat1_verify_ed25519

  subroutine chat1_crypto_selftest(is_valid, err)
    logical, intent(out) :: is_valid
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: backend_path, output_path, command, output
    integer :: exitstat, cmdstat

    call chat1_clear_error(err)
    is_valid = .false.

    output_path = temp_path('selftest_output.txt')
    backend_path = backend_script_path()
    command = 'python3 "' // backend_path // '" selftest "' // output_path // '"'
    call execute_command_line(command, exitstat=exitstat, cmdstat=cmdstat)
    if (cmdstat /= 0 .or. exitstat /= 0) then
      call chat1_set_error(err, 'crypto-failed', 'crypto selftest failed')
      call cleanup_paths(output_path)
      return
    end if

    call read_text_file(output_path, output, err)
    call cleanup_paths(output_path)
    if (.not. err%ok) return

    is_valid = trim(strip_newline(output)) == 'OK'
  end subroutine chat1_crypto_selftest

  function backend_script_path() result(path)
    character(len=:), allocatable :: path
    character(len=1024) :: env_value
    integer :: env_len, status

    call get_environment_variable('CHAT1_CRYPTO_BACKEND', env_value, length=env_len, status=status)
    if (status == 0 .and. env_len > 0) then
      path = trim(env_value(1:env_len))
    else
      path = 'tools/chat1_crypto_backend.py'
    end if
  end function backend_script_path

  function temp_path(suffix) result(path)
    character(len=*), intent(in) :: suffix
    character(len=:), allocatable :: path
    integer :: count, values(8)
    character(len=32) :: count_text, millis_text

    call system_clock(count=count)
    call date_and_time(values=values)
    write(count_text, '(I0)') count
    write(millis_text, '(I0.3)') values(8)
    path = '/tmp/chat1_' // trim(count_text) // '_' // trim(millis_text) // '_' // trim(suffix)
  end function temp_path

  subroutine write_binary_file(path, text, err)
    character(len=*), intent(in) :: path
    character(len=*), intent(in) :: text
    type(chat1_error), intent(out) :: err
    integer :: unit, ios

    call chat1_clear_error(err)
    open(newunit=unit, file=path, access='stream', form='unformatted', status='replace', action='write', iostat=ios)
    if (ios /= 0) then
      call chat1_set_error(err, 'io-failed', 'cannot open temp file for write')
      return
    end if
    write(unit, iostat=ios) text
    close(unit)
    if (ios /= 0) then
      call chat1_set_error(err, 'io-failed', 'cannot write temp file')
    end if
  end subroutine write_binary_file

  subroutine read_text_file(path, text, err)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: text
    type(chat1_error), intent(out) :: err
    integer :: unit, ios, size_bytes

    call chat1_clear_error(err)
    if (allocated(text)) deallocate(text)

    inquire(file=path, size=size_bytes, iostat=ios)
    if (ios /= 0 .or. size_bytes < 0) then
      call chat1_set_error(err, 'io-failed', 'cannot stat output file')
      text = ''
      return
    end if

    allocate(character(len=size_bytes) :: text)
    if (size_bytes == 0) return

    open(newunit=unit, file=path, access='stream', form='unformatted', status='old', action='read', iostat=ios)
    if (ios /= 0) then
      call chat1_set_error(err, 'io-failed', 'cannot open output file')
      return
    end if

    read(unit, iostat=ios) text
    close(unit)
    if (ios /= 0) then
      call chat1_set_error(err, 'io-failed', 'cannot read output file')
      return
    end if
  end subroutine read_text_file

  function strip_newline(text) result(clean)
    character(len=*), intent(in) :: text
    character(len=:), allocatable :: clean
    integer :: n

    n = len(text)
    clean = text
    do while (n > 0 .and. (clean(n:n) == new_line('a') .or. clean(n:n) == achar(13)))
      n = n - 1
    end do
    if (n <= 0) then
      clean = ''
    else
      clean = clean(1:n)
    end if
  end function strip_newline

  subroutine cleanup_paths(path1, path2)
    character(len=*), intent(in) :: path1
    character(len=*), intent(in), optional :: path2
    character(len=:), allocatable :: command
    integer :: exitstat, cmdstat

    if (present(path2)) then
      command = 'rm -f "' // trim(path1) // '" "' // trim(path2) // '"'
    else
      command = 'rm -f "' // trim(path1) // '"'
    end if
    call execute_command_line(command, exitstat=exitstat, cmdstat=cmdstat)
  end subroutine cleanup_paths

end module chat1_crypto
