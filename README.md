# sirven

Secure access levels for your personal agent. Install it, own it, no hosted middleman.

- [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md): install in three steps
- [docs/PERMISSIONS.md](docs/PERMISSIONS.md): the access levels and what each one allows
- [docs/phone-interface.md](docs/phone-interface.md): let your agent drive your own plugged-in
  iPhone, opt in per session, every action logged in plain words

## Credits

- The iPhone integration follows the approach of
  [iPhone-use](https://github.com/zhongerxin/iPhone-use) by ZHONG XIN (MIT license): an agent
  drives a real iPhone over USB through WebDriverAgent. sirven's integration layer is its own
  code.
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) is from the Appium project (BSD
  license). You fetch and sign it yourself at setup; sirven does not bundle it.
