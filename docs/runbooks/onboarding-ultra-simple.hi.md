# अल्ट्रा-सरल ऑनबोर्डिंग (हिंदी) - DGX Agentic Stack

लक्षित उपयोगकर्ता: पूरी तरह गैर-तकनीकी उपयोगकर्ता।  
उद्देश्य: प्लेटफ़ॉर्म क्या करता है यह जल्दी समझना, और बुनियादी काम सुरक्षित तरीके से करना।

## 1) एक वाक्य में

यह प्लेटफ़ॉर्म लोकल AI, वेब इंटरफेस और मॉनिटरिंग टूल्स चलाता है, और डिफ़ॉल्ट रूप से अधिक सुरक्षित तरीके से काम करता है: केवल लोकल एड्रेस पर एक्सपोज़र और नियंत्रित आउटबाउंड ट्रैफ़िक।

यह त्वरित गाइड मौजूदा रोज़मर्रा वाले मोड `rootless-dev` को मानकर लिखी गई है।

## 2) याद रखने के 6 हिस्से

1. `core` = तकनीकी आधार (AI + DNS + प्रॉक्सी + OpenClaw / `gate-mcp` जैसे आंतरिक कंट्रोल सर्विसेज)।
2. `agents` = अलग-अलग वर्कस्पेस में काम करने वाले सहायक।
3. `ui` = वेब स्क्रीन जिन्हें आप खोलते हैं।
4. `obs` = डैशबोर्ड (स्वास्थ्य, लॉग, मेट्रिक्स)।
5. `rag` = दस्तावेज़ मेमोरी और semantic search।
6. `optional` = अतिरिक्त मॉड्यूल, जिन्हें केवल ज़रूरत होने पर चालू किया जाता है।

## 3) मुख्य वेब पते

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

महत्वपूर्ण: ये सभी लोकल पते हैं।  
दूसरी मशीन से एक्सेस के लिए SSH / Tailscale टनल का उपयोग करें।

## 4) न्यूनतम कमांड

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
./agent first-up
./agent ps
./agent doctor
```

अगर आप चरण-दर-चरण शुरू करना चाहते हैं:

```bash
./agent up core
./agent up agents,ui,obs,rag
```

साफ़ तरीके से बंद करने के लिए:

```bash
./agent stack stop all
```

## 5) कैसे पता चले कि सब ठीक है

सरल नियम:
- `./agent ps` में सेवाएँ `Up` दिखनी चाहिए
- `./agent doctor` बिना blocking errors के पूरा होना चाहिए

अगर कोई सेवा फेल हो:

```bash
./agent logs <service>
```

उदाहरण:

```bash
./agent logs openwebui
```

## 6) आसान सुरक्षा नियम

- सेवाओं को `0.0.0.0` पर एक्सपोज़ न करें
- एप्लिकेशन कंटेनरों में `docker.sock` माउंट न करें
- secrets को git में न रखें
- remote access केवल Tailscale / SSH से रखें

## 7) अपडेट और रोलबैक

अपडेट:

```bash
./agent update
```

रोलबैक:

```bash
./agent rollback all <release_id>
```

## 8) आगे क्या पढ़ें

- फ़्रेंच विस्तृत beginner guide: `docs/runbooks/services-expliques-debutants.md`
- English detailed beginner guide: `docs/runbooks/services-explained-beginners.en.md`
- पूरा first-time setup: `docs/runbooks/first-time-setup.md`
- चीनी (सरल) संस्करण: `docs/runbooks/onboarding-ultra-simple.cn.md`
