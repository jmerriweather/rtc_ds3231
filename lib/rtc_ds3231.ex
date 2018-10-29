defmodule RtcDs3231 do
  use GenServer

  alias ElixirALE.I2C

  require Logger

  defmodule State do
    @enforce_keys [:i2c_device, :i2c_address]
    defstruct [:i2c_device, :i2c_address, :set_time_on_boot, :device_pid]
  end

  def start_link(opts) do
    {i2c_device, opts} = Keyword.pop(opts, :i2c_device, "i2c-2")
    {i2c_address, opts} = Keyword.pop(opts, :i2c_address, 0x68)
    {set_time_on_boot, opts} = Keyword.pop(opts, :set_time_on_boot, false)
    GenServer.start(__MODULE__, %State{i2c_device: i2c_device, i2c_address: i2c_address, set_time_on_boot: set_time_on_boot}, opts)
  end

  def get_datetime(pid) do
    GenServer.call(pid, :get_datetime)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: { __MODULE__, :start_link, [opts]}
    }
  end

  def init(%State{} = opts) do
    {:ok, opts, {:continue, :initialise_rtc}}
  end
\
  def handle_continue(:initialise_rtc, state = %State{i2c_device: i2c_device, i2c_address: i2c_address, set_time_on_boot: set_time_on_boot}) do
    {:ok, pid} = I2C.start_link(i2c_device, i2c_address)

    if set_time_on_boot do
      {:noreply, %{state | device_pid: pid}, {:continue, :set_datetime}}
    else
      {:noreply, %{state | device_pid: pid}}
    end
  end

  def handle_continue(:set_datetime, state = %{device_pid: pid}) do
    with rtc_bytes <- bytes_from_rtc(pid),
         erl_date <- rtcbytes_to_erl(rtc_bytes),
         {:ok, parsed_datetime} <- NaiveDateTime.from_erl(erl_date) do

      string_time = parsed_datetime |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

      case System.cmd("date", ["-u", "-s", string_time]) do
        {_result, 0} ->
          Logger.info("rtc_ds3231 initialized clock to #{string_time} UTC")

        {message, code} ->
          Logger.error(
            "rtc_ds3231 failed to set date/time to '#{string_time}': #{code} #{inspect(message)}"
          )
      end
    else
      error ->
        Logger.error("rtc_ds3231 failed to request current datetime from RTC: #{inspect error}")
    end

    {:noreply, state}
  end

  def handle_call(:get_datetime, state = %{device_pid: pid}) do
    current_datetime = bytes_from_rtc(pid)
    |> rtcbytes_to_erl()
    |> NaiveDateTime.from_erl


    {:reply, current_datetime, state}
  end

  def bytes_from_rtc(pid) do
    second_byte = I2C.write_read(pid, <<0x00>>, 1)
    minute_byte = I2C.write_read(pid, <<0x01>>, 1)
    hour_byte = I2C.write_read(pid, <<0x02>>, 1)
    date_byte = I2C.write_read(pid, <<0x04>>, 1)
    month_byte = I2C.write_read(pid, <<0x05>>, 1)
    year_byte = I2C.write_read(pid, <<0x06>>, 1)

    %{second: second_byte, minute: minute_byte, hour: hour_byte, date: date_byte, month: month_byte, year: year_byte}
  end

  def rtcbytes_to_erl(%{second: second_byte, minute: minute_byte, hour: hour_byte, date: date_byte, month: month_byte, year: year_byte}) do
    second = RtcDs3231.decode_bcd(second_byte)
    minute = RtcDs3231.decode_bcd(minute_byte)
    hour = parse_hour(hour_byte)
    date = RtcDs3231.decode_bcd(date_byte)
    month = parse_month(month_byte)
    year = String.to_integer("20#{RtcDs3231.decode_bcd(year_byte)}")

    {{year, month, date}, {hour, minute, second}}
  end

  def parse_month(<<_::size(1), rest::bitstring>>) do
    RtcDs3231.decode_bcd(<<0::size(1), rest::bitstring>>)
  end

  def parse_hour(<<0::size(1), rest::bitstring>>) do
    RtcDs3231.decode_bcd(<<0::size(1), rest::bitstring>>)
  end

  # AM
  def parse_hour(<<1::size(1), 0::size(1), rest::bitstring>>) do
    RtcDs3231.decode_bcd(<<0::size(2), rest::bitstring>>)
  end

  # PM
  def parse_hour(<<1::size(1), 1::size(1), rest::bitstring>>) do
    hour = RtcDs3231.decode_bcd(<<0::size(2), rest::bitstring>>)
    hour + 12
  end


  def decode_bcd(binary), do: decode_bcd(binary, 0)
  def decode_bcd(<<n1::size(4), n2::size(4), rest::binary>>, number) do
    decode_bcd(rest, number + (10 * n1) + n2)
  end
  def decode_bcd(_, number) do
    number
  end
end
