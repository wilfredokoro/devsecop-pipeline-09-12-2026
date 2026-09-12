package com.gavok.demo;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
@RestController
public class HelloController {
    @GetMapping("/")
    public Map<String, String> index() {
        return Map.of("application", "Gavok DevSecOps Demo", "status", "running");
    }
    @GetMapping("/api/hello")
    public Map<String, String> hello() { return Map.of("message", "Hello from a security-gated pipeline"); }
}
