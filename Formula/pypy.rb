class Pypy < Formula
  desc "Highly performant implementation of Python 2 in Python"
  homepage "https://pypy.org/"
  url "https://downloads.python.org/pypy/pypy2.7-v7.3.3-src.tar.bz2"
  sha256 "f63488051ba877fd65840bf8d53822a9c6423d947839023b8720139f4b6e2336"
  license "MIT"
  head "https://foss.heptapod.net/pypy/pypy", using: :hg

  livecheck do
    url "https://downloads.python.org/pypy/"
    regex(/href=.*?pypy2(?:\.\d+)*[._-]v?(\d+(?:\.\d+)+)-src\.t/i)
  end

  bottle do
    cellar :any
    sha256 "61e8cfe37e26b93cd72b7fa8d758d71c52181bc1e2a04f6221811018237bade1" => :catalina
    sha256 "8b6ec82f015f6481f44f30d0d01907872129197efc03bebbc2c14edb54bf598d" => :mojave
    sha256 "08f78b30b0a831ce06cfa27f9d1f82efbffa3ff9a3997ba8e6129bfefe9e337d" => :high_sierra
  end

  depends_on "pkg-config" => :build
  depends_on arch: :x86_64
  depends_on "gdbm"
  # pypy does not find system libffi, and its location cannot be given
  # as a build option
  depends_on "libffi"
  depends_on "openssl@1.1"
  depends_on "sqlite"
  depends_on "tcl-tk"

  uses_from_macos "expat"
  uses_from_macos "unzip"
  uses_from_macos "zlib"

  resource "bootstrap" do
    url "https://downloads.python.org/pypy/pypy2.7-v7.3.2-osx64.tar.bz2"
    version "7.3.2"
    sha256 "10ca57050793923aea3808b9c8669cf53b7342c90c091244e9660bf797d397c7"
  end

  resource "setuptools" do
    url "https://files.pythonhosted.org/packages/a7/e0/30642b9c2df516506d40b563b0cbd080c49c6b3f11a70b4c7a670f13a78b/setuptools-50.3.2.zip"
    sha256 "ed0519d27a243843b05d82a5e9d01b0b083d9934eaa3d02779a23da18077bd3c"
  end

  resource "pip" do
    url "https://files.pythonhosted.org/packages/0b/f5/be8e741434a4bf4ce5dbc235aa28ed0666178ea8986ddc10d035023744e6/pip-20.2.4.tar.gz"
    sha256 "85c99a857ea0fb0aedf23833d9be5c40cf253fe24443f0829c7b472e23c364a1"
  end

  def install
    # Fix Xcode 12 implicit function declaration errors.
    ENV.append "CFLAGS", "-Wno-implicit-function-declaration"
    # Having PYTHONPATH set can cause the build to fail if another
    # Python is present, e.g. a Homebrew-provided Python 2.x
    # See https://github.com/Homebrew/homebrew/issues/24364
    ENV["PYTHONPATH"] = ""
    ENV["PYPY_USESSION_DIR"] = buildpath

    # Brutally hack at RPython internals to return the correct path to libc.
    # CPython attempts to read from this file, which doesn't exist on Big Sur due to
    # the shared dylib cache. This has been patched by CPython upstream and is fixed
    # in Apple's Python but hasn't yet been backported to RPython.
    # https://github.com/python/cpython/pull/21241
    # https://foss.heptapod.net/pypy/pypy/-/issues/3314
    # The correct path can be found with:
    #   /usr/bin/python -c "import ctypes.util; print(ctypes.util.find_library('c'))"
    inreplace "rpython/rlib/clibffi.py", "ctypes.util.find_library('c')", "'/usr/lib/libc.dylib'"

    resource("bootstrap").stage buildpath/"bootstrap"
    python = buildpath/"bootstrap/bin/pypy"

    cd "pypy/goal" do
      system python, buildpath/"rpython/bin/rpython",
             "-Ojit", "--shared", "--cc", ENV.cc, "--verbose",
             "--make-jobs", ENV.make_jobs, "targetpypystandalone.py"
    end

    libexec.mkpath
    cd "pypy/tool/release" do
      package_args = %w[--archive-name pypy --targetdir .]
      system python, "package.py", *package_args
      system "tar", "-C", libexec.to_s, "--strip-components", "1", "-xf", "pypy.tar.bz2"
    end

    (libexec/"lib").install libexec/"bin/#{shared_library("libpypy-c")}"
    MachO::Tools.change_install_name("#{libexec}/bin/pypy",
                                     "@rpath/libpypy-c.dylib",
                                     "#{libexec}/lib/libpypy-c.dylib")

    # The PyPy binary install instructions suggest installing somewhere
    # (like /opt) and symlinking in binaries as needed. Specifically,
    # we want to avoid putting PyPy's Python.h somewhere that configure
    # scripts will find it.
    bin.install_symlink libexec/"bin/pypy"
    lib.install_symlink libexec/"lib/#{shared_library("libpypy-c")}"
  end

  def post_install
    # Post-install, fix up the site-packages and install-scripts folders
    # so that user-installed Python software survives minor updates, such
    # as going from 1.7.0 to 1.7.1.

    # Create a site-packages in the prefix.
    prefix_site_packages.mkpath

    # Symlink the prefix site-packages into the cellar.
    unless (libexec/"site-packages").symlink?
      # fix the case where libexec/site-packages/site-packages was installed
      rm_rf libexec/"site-packages/site-packages"
      mv Dir[libexec/"site-packages/*"], prefix_site_packages
      rm_rf libexec/"site-packages"
    end
    libexec.install_symlink prefix_site_packages

    # Tell distutils-based installers where to put scripts
    scripts_folder.mkpath
    (distutils+"distutils.cfg").atomic_write <<~EOS
      [install]
      install-scripts=#{scripts_folder}
    EOS

    %w[setuptools pip].each do |pkg|
      resource(pkg).stage do
        system bin/"pypy", "-s", "setup.py", "--no-user-cfg", "install",
               "--force", "--verbose"
      end
    end

    # Symlinks to easy_install_pypy and pip_pypy
    bin.install_symlink scripts_folder/"easy_install" => "easy_install_pypy"
    bin.install_symlink scripts_folder/"pip" => "pip_pypy"

    # post_install happens after linking
    %w[easy_install_pypy pip_pypy].each { |e| (HOMEBREW_PREFIX/"bin").install_symlink bin/e }
  end

  def caveats
    <<~EOS
      A "distutils.cfg" has been written to:
        #{distutils}
      specifying the install-scripts folder as:
        #{scripts_folder}

      If you install Python packages via "pypy setup.py install", easy_install_pypy,
      or pip_pypy, any provided scripts will go into the install-scripts folder
      above, so you may want to add it to your PATH *after* #{HOMEBREW_PREFIX}/bin
      so you don't overwrite tools from CPython.

      Setuptools and pip have been installed, so you can use easy_install_pypy and
      pip_pypy.
      To update setuptools and pip between pypy releases, run:
          pip_pypy install --upgrade pip setuptools

      See: https://docs.brew.sh/Homebrew-and-Python
    EOS
  end

  # The HOMEBREW_PREFIX location of site-packages
  def prefix_site_packages
    HOMEBREW_PREFIX+"lib/pypy/site-packages"
  end

  # Where setuptools will install executable scripts
  def scripts_folder
    HOMEBREW_PREFIX+"share/pypy"
  end

  # The Cellar location of distutils
  def distutils
    libexec+"lib-python/2.7/distutils"
  end

  test do
    system bin/"pypy", "-c", "print('Hello, world!')"
    system bin/"pypy", "-c", "import time; time.clock()"
    system scripts_folder/"pip", "list"
  end
end
