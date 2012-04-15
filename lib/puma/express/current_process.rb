class Puma::Express::CurrentProcess
  def detect?(path)
    File.exists? File.join(path, "config.ru")
  end

  def run

  end
end
